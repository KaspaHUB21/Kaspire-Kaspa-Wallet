//! TN10-only Forge 3.3 orders. Public SDK 0.4.0 templates are data, not code.
//! Never use the provider's checkOrder verdict as signing authority.
use crate::{CoreError, PsktRequest, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    hashing::sighash_type::SigHashType,
    tx::{Transaction, UtxoEntry},
};
use kaspa_txscript::{
    pay_to_address_script, pay_to_script_hash_script, script_builder::ScriptBuilder,
};
use serde_json::Value;
use std::collections::HashSet;

fn bad(s: &str) -> CoreError {
    CoreError::InvalidRequest(format!("KasForge: {s}"))
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or_else(|| bad("missing text field"))
}
fn num(v: &Value, k: &str) -> Result<u64> {
    let s = v[k]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| v[k].to_string());
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) || s.len() > 19 {
        return Err(bad("invalid integer"));
    }
    s.parse::<u64>()
        .ok()
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or_else(|| bad("integer overflow"))
}
fn bytes(s: &str) -> Result<Vec<u8>> {
    hex::decode(s).map_err(|_| bad("invalid hex"))
}
fn key(s: &str) -> Result<Vec<u8>> {
    let b = bytes(s)?;
    if b.len() != 32 {
        return Err(bad("invalid identity"));
    }
    Ok(b)
}
fn hash(b: &[u8]) -> String {
    hex::encode(
        kaspa_hashes::blake2b_simd::Params::new()
            .hash_length(32)
            .hash(b)
            .as_bytes(),
    )
}
fn templates() -> Value {
    serde_json::from_str(include_str!("kasforge_templates.json")).expect("pinned public templates")
}
fn push(b: &[u8]) -> Result<Vec<u8>> {
    ScriptBuilder::new()
        .add_data(b)
        .map(|v| v.drain())
        .map_err(|_| bad("script push"))
}
pub(crate) fn order_program(order: &Value) -> Result<Vec<u8>> {
    let s = &order["state"];
    let t = templates();
    let name = if !s["unitsIn"].is_null() {
        "ForgeBuyOrder"
    } else if !s["refundGuard"].is_null() {
        "ForgeSellOrder"
    } else {
        "ForgeSellOrder_v1"
    };
    if num(s, "refundFee")? != 1_000_000 {
        return Err(bad("unexpected refund fee"));
    }
    let mut out = Vec::new();
    if name == "ForgeBuyOrder" {
        if num(s, "creatorBps")? != 50
            || num(s, "feeBps")? != 100
            || num(s, "feeMin")? != 20_000_000
            || num(s, "tokenDust")? != 100_000_000
            || s["templateHash"] != t[name]["templateHash"]
        {
            return Err(bad("unknown buy constants"));
        }
        out.extend(bytes(text(&t[name], "prefix")?)?);
        for f in ["owner", "market", "kcc20"] {
            out.extend(push(&key(text(s, f)?)?)?);
        }
        for f in ["unitsIn", "minTokens", "expiryDaa"] {
            out.push(8);
            out.extend(num(s, f)?.to_le_bytes());
        }
        out.extend(bytes(text(&t[name], "suffix")?)?);
    } else {
        if num(s, "tip")? > 5_000_000 {
            return Err(bad("unexpected settlement tip"));
        }
        for p in t[name]["parts"]
            .as_array()
            .ok_or_else(|| bad("template parts"))?
        {
            if let Some(h) = p["hex"].as_str() {
                out.extend(bytes(h)?);
                continue;
            }
            let f = match text(p, "slot")? {
                "marketCovid" => "market",
                "kcc20Covid" => "kcc20",
                "tipSompi" => "tip",
                x => x,
            };
            if p["kind"] == "bytes32" {
                out.extend(push(&key(text(s, f)?)?)?);
            } else {
                out.extend(
                    ScriptBuilder::new()
                        .add_i64(num(s, f)? as i64)
                        .map_err(|_| bad("script number"))?
                        .drain(),
                );
            }
        }
    }
    if hex::encode(&out) != text(order, "redeemScript")? || hash(&out) != text(order, "scriptHash")?
    {
        return Err(bad("order does not match pinned program and state"));
    }
    let address = Address::try_from(text(order, "address")?).map_err(|_| bad("order address"))?;
    if address.prefix != Prefix::Testnet
        || pay_to_address_script(&address) != pay_to_script_hash_script(&out)
    {
        return Err(bad("order address differs"));
    }
    Ok(out)
}
#[derive(Clone)]
struct Note {
    amount: u64,
    owner: Vec<u8>,
    scheme: u8,
    borrow: u8,
    guard: Vec<u8>,
}
fn note_program(n: &Note) -> Result<Vec<u8>> {
    let t = templates();
    let t = &t["KCC20"];
    let mut r = bytes(text(t, "prefix")?)?;
    r.extend(push(&key(text(t, "templateHash")?)?)?);
    r.push(8);
    r.extend(n.amount.to_le_bytes());
    r.extend(push(&n.owner)?);
    r.extend([1, n.scheme, 1, n.borrow]);
    r.extend(push(&n.guard)?);
    r.extend(push(&[0; 32])?);
    r.extend(bytes(text(t, "suffix")?)?);
    Ok(r)
}
fn parse_note(r: &[u8]) -> Result<Note> {
    if r.len() < 146
        || r[0] != 0x6b
        || r[1] != 32
        || r[34] != 8
        || r[43] != 32
        || r[76] != 1
        || r[78] != 1
        || r[80] != 32
        || r[113] != 32
    {
        return Err(bad("malformed token program"));
    }
    let n = Note {
        amount: u64::from_le_bytes(r[35..43].try_into().unwrap()),
        owner: r[44..76].to_vec(),
        scheme: r[77],
        borrow: r[79],
        guard: r[81..113].to_vec(),
    };
    if n.amount > i64::MAX as u64 || n.borrow > 2 || note_program(&n)? != r {
        return Err(bad("unrecognized token program or extension"));
    }
    Ok(n)
}
fn witness(
    next: &[Note],
    redeem: &[u8],
    leader: bool,
    script_owner: bool,
) -> Result<(Vec<u8>, usize)> {
    let mut r = Vec::new();
    if leader {
        for column in 0..6 {
            let data = next
                .iter()
                .flat_map(|n| match column {
                    0 => n.amount.to_le_bytes().to_vec(),
                    1 => n.owner.clone(),
                    2 => vec![n.scheme],
                    3 => vec![n.borrow],
                    4 => n.guard.clone(),
                    _ => vec![0; 32],
                })
                .collect::<Vec<_>>();
            r.extend(push(&data)?);
        }
    }
    let slot = r.len() + 1 + usize::from(leader);
    r.extend(push(&if script_owner {
        vec![0, 1]
    } else {
        vec![0; if leader { 66 } else { 65 }]
    })?);
    r.extend(push(&bytes(if leader { "79c71c23" } else { "fd3ef14a" })?)?);
    r.extend(push(redeem)?);
    Ok((r, slot))
}
fn token_signature_template(next: &[Note], leader: bool) -> Value {
    let mut args = vec![];
    if leader {
        for column in 0..6 {
            let data = next
                .iter()
                .flat_map(|n| match column {
                    0 => n.amount.to_le_bytes().to_vec(),
                    1 => n.owner.clone(),
                    2 => vec![n.scheme],
                    3 => vec![n.borrow],
                    4 => n.guard.clone(),
                    _ => vec![0; 32],
                })
                .collect::<Vec<_>>();
            args.push(serde_json::json!({"type":"data","hex":hex::encode(data)}));
        }
    }
    args.push(serde_json::json!({"type":"signature","prefixHex":if leader{"00"}else{""}}));
    args.push(serde_json::json!({"type":"data","hex":if leader{"79c71c23"}else{"fd3ef14a"}}));
    serde_json::json!({"mode":"ordered-args","args":args})
}
pub(crate) fn validate(
    r: &PsktRequest,
    tx: &Transaction,
    entries: &[UtxoEntry],
    signatures: &[(usize, SigHashType)],
) -> Result<()> {
    let sender = Address::try_from(r.sender.as_str()).map_err(|_| bad("sender"))?;
    let s = r
        .trade_summary
        .as_ref()
        .ok_or_else(|| bad("missing review"))?;
    let order = &s["order"];
    let st = &order["state"];
    if text(st,"kcc20")?!=text(s,"tokenId")?||text(st,"market")?!=text(s,"marketId")? {
        return Err(bad("order token or market differs from the selected quote"));
    }
    let redeem = order_program(order)?;
    let order_spk = pay_to_script_hash_script(&redeem);
    let wallet = pay_to_address_script(&sender);
    if sender.prefix != Prefix::Testnet
        || sender.version != Version::PubKey
        || text(st, "owner")? != hex::encode(&sender.payload)
        || tx.version != 1
        || tx.inputs.len() > 32
        || tx.outputs.len() > 8
        || tx.gas != 0
        || !tx.payload.is_empty()
        || signatures.iter().any(|(_, h)| h.to_u8() != 1)
        || tx.inputs.iter().any(|i| i.sequence != 0)
    {
        return Err(bad("network, owner or transaction policy differs"));
    }
    let selected = signatures.iter().map(|(i, _)| *i).collect::<HashSet<_>>();
    let input_total = entries
        .iter()
        .try_fold(0u64, |sum, e| sum.checked_add(e.amount))
        .ok_or_else(|| bad("input overflow"))?;
    let output_total = tx
        .outputs
        .iter()
        .try_fold(0u64, |sum, o| sum.checked_add(o.value))
        .ok_or_else(|| bad("output overflow"))?;
    let fee = input_total
        .checked_sub(output_total)
        .ok_or_else(|| bad("unfunded transaction"))?;
    if fee > 10_000_000 {
        return Err(bad("network fee exceeds 0.1 KAS"));
    }
    let action = text(s, "action")?;
    let sell = st["unitsIn"].is_null();
    let mut token_inputs = Vec::new();
    let mut token_total = 0u64;
    let mut funding = 0u64;
    let recovery = action == "cancel";
    let mut expected_signatures = HashSet::new();
    for (i, e) in entries.iter().enumerate() {
        if !recovery && e.script_public_key == wallet && e.covenant_id.is_none() {
            funding = funding
                .checked_add(e.amount)
                .ok_or_else(|| bad("funding overflow"))?;
            expected_signatures.insert(i);
            continue;
        }
        if recovery && e.script_public_key == order_spk && e.covenant_id.is_none() {
            let point = &tx.inputs[i].previous_outpoint;
            if format!("{}:{}", point.transaction_id, point.index)
                != text(&order["output"], "outpoint")?
                || e.amount != num(&order["output"], "sompi")?
            {
                return Err(bad("different saved order outpoint"));
            }
            expected_signatures.insert(i);
            continue;
        }
        let raw = bytes(text(&s["inputRedeems"], &i.to_string())?)?;
        let n = parse_note(&raw)?;
        let expected_owner = if recovery {
            bytes(text(order, "scriptHash")?)?
        } else {
            sender.payload.to_vec()
        };
        if n.owner != expected_owner
            || n.scheme != if recovery { 3 } else { 0 }
            || e.covenant_id.map(|h| h.to_string()).as_deref() != Some(text(st, "kcc20")?)
            || e.script_public_key != pay_to_script_hash_script(&raw)
        {
            return Err(bad("foreign token input"));
        }
        let point = &tx.inputs[i].previous_outpoint;
        if recovery
            && format!("{}:{}", point.transaction_id, point.index)
                != text(&order["tokens"]["output"], "outpoint")?
        {
            return Err(bad("different saved token outpoint"));
        }
        token_total = token_total
            .checked_add(n.amount)
            .ok_or_else(|| bad("token overflow"))?;
        token_inputs.push((i, raw));
        if !recovery {
            expected_signatures.insert(i);
        }
    }
    if selected != expected_signatures || token_inputs.len() > 3 {
        return Err(bad("unexpected signing inputs"));
    }
    let mut next = Vec::new();
    let mut owned_change = 0u64;
    let mut order_count = 0;
    let mut token_outputs = 0u64;
    let oi = num(&order["output"], "index")? as usize;
    let mut allowed_coin = if recovery { 0 } else { 1 };
    for (i, o) in tx.outputs.iter().enumerate() {
        if o.script_public_key == wallet && o.covenant.is_none() {
            owned_change = owned_change
                .checked_add(o.value)
                .ok_or_else(|| bad("change overflow"))?;
            continue;
        }
        if !recovery
            && i == oi
            && o.script_public_key == order_spk
            && o.covenant.is_none()
            && o.value == num(&order["output"], "sompi")?
        {
            order_count += 1;
            continue;
        }
        let program = bytes(text(&s["outputRedeems"], &i.to_string())?)?;
        let n = parse_note(&program)?;
        let token_order =
            !recovery && sell && i == num(&order["tokens"]["output"], "index")? as usize;
        let owner = if token_order {
            bytes(text(order, "scriptHash")?)?
        } else {
            sender.payload.to_vec()
        };
        let binding = o
            .covenant
            .as_ref()
            .ok_or_else(|| bad("token output covenant missing"))?;
        let policy = if token_order || recovery {
            n.borrow == 0 && n.guard == vec![0; 32]
        } else {
            (n.borrow <= 1 && n.guard == vec![0; 32])
                || (n.borrow == 2
                    && st["refundGuard"]
                        .as_str()
                        .is_some_and(|g| hex::encode(&n.guard) == g))
        };
        if n.owner != owner
            || n.scheme != if token_order { 3 } else { 0 }
            || !policy
            || o.value != 100_000_000
            || binding.covenant_id.to_string() != text(st, "kcc20")?
            || !token_inputs
                .iter()
                .any(|(idx, _)| *idx == binding.authorizing_input as usize)
            || o.script_public_key != pay_to_script_hash_script(&program)
        {
            return Err(bad("token output changes owner, policy or deposit"));
        }
        if token_order
            && (n.amount != num(st, "amount")?
                || text(&order["tokens"]["output"], "outpoint")? != format!("{}:{i}", tx.id())
                || num(&order["tokens"]["output"], "sompi")? != o.value
                || text(&order["tokens"],"redeemScript")?!=hex::encode(&program))
        {
            return Err(bad("wrong sold amount or recovery outpoint"));
        }
        token_outputs = token_outputs
            .checked_add(n.amount)
            .ok_or_else(|| bad("token output overflow"))?;
        next.push(n);
    }
    if token_total != token_outputs {
        return Err(bad("token conservation failed"));
    }
    for (position, (i, program)) in token_inputs.iter().enumerate() {
        let (expected, _) = witness(&next, program, position == 0, recovery)?;
        if if recovery {
            tx.inputs[*i].signature_script != expected
        } else {
            !tx.inputs[*i].signature_script.is_empty()
        } {
            return Err(bad("token witness differs from reconstructed outputs"));
        }
        if !recovery {
            let script = r
                .scripts
                .iter()
                .find(|s| s.input_index == *i)
                .ok_or_else(|| bad("token signature template missing"))?;
            if script.prebuilt_signature_script.is_some()
                || !script.signature_offsets.is_empty()
                || script.script_hex != hex::encode(program)
                || serde_json::to_value(&script.signature_script).ok()
                    != Some(token_signature_template(&next, position == 0))
            {
                return Err(bad("different token signing template"));
            }
        }
    }
    if recovery {
        allowed_coin = 1;
        if tx.inputs.len()!=usize::from(sell)+1||next.len()!=usize::from(sell)||!r.scripts.iter().any(|script|script.script_hex==hex::encode(&redeem)&&serde_json::to_value(&script.signature_script).ok()==Some(serde_json::json!({"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"a0893109"}]}))){return Err(bad("cancel branch or outputs differ"));}
        if fee > 10_000_000 || tx.lock_time != 0 {
            return Err(bad("cancel fee or locktime differs"));
        }
    } else {
        if action != "order-buy" && action != "order-sell" && action != "merge" {
            return Err(bad("unsupported action"));
        }
        let a = num(s, "chainDaa")?;
        let b = num(s, "secondChainDaa")?;
        let expiry = num(st, "expiryDaa")?;
        if a == 0
            || a.abs_diff(b) > 600
            || expiry < a.max(b) + 1800
            || expiry > a.max(b) + 37000
            || tx.lock_time != 0
        {
            return Err(bad("expiry outside reviewed chain-time window"));
        }
        if action == "merge" {
            if !sell
                || order_count != 0
                || next.len() != 1
                || tx.outputs.len() != 2
                || funding.saturating_sub(owned_change) > 5_000_000
            {
                return Err(bad("merge moves funds outside wallet"));
            }
        } else {
            if order_count != 1
                || text(&order["output"], "outpoint")? != format!("{}:{oi}", tx.id())
            {
                return Err(bad("order outpoint differs from locally computed ID"));
            }
            if sell {
                if action != "order-sell"
                    || num(st, "amount")? != num(s, "amount")?
                    || num(st, "minSompi")? < num(s, "minimumOut")?
                    || funding.saturating_sub(owned_change) > 210_000_000
                    || token_inputs.is_empty()
                    || num(&order["output"], "sompi")? != 100_000_000
                {
                    return Err(bad("sale differs from review"));
                }
            } else {
                if action != "order-buy"
                    || !next.is_empty()
                    || !token_inputs.is_empty()
                    || num(st, "minTokens")? < num(s, "minimumOut")?
                    || funding
                        .checked_sub(owned_change)
                        .ok_or_else(|| bad("buy debit"))?
                        > num(s, "maximumDebit")?
                    || num(st, "unitsIn")?
                        .checked_mul(1_000_000)
                        .ok_or_else(|| bad("buy amount overflow"))?
                        > num(s, "amount")?
                {
                    return Err(bad("buy differs from reviewed limits"));
                }
            }
        }
    }
    if allowed_coin != 1 || r.scripts.len() != if recovery { 1 } else { token_inputs.len() } {
        return Err(bad("unexpected script instructions"));
    }
    // Size actual signatures and redeem programs, not the API's empty inputs.
    use kaspa_consensus_core::{config::params::MAINNET_PARAMS,mass::MassCalculator,tx::PopulatedTransaction};
    let mut estimate=tx.clone();estimate.set_storage_mass(0);
    for i in &selected {
        estimate.inputs[*i].signature_script=if let Some(position)=token_inputs.iter().position(|(idx,_)|idx==i){witness(&next,&token_inputs[position].1,position==0,false)?.0}
        else if recovery{[push(&[0;65])?,push(&bytes("a0893109")?)?,push(&redeem)?].concat()}
        else{push(&[0;65])?};
    }
    let calc=MassCalculator::new(MAINNET_PARAMS.mass_per_tx_byte,MAINNET_PARAMS.mass_per_script_pub_key_byte,MAINNET_PARAMS.storage_mass_parameter);
    let non=calc.calc_non_contextual_masses(&estimate);
    let ctx=calc.calc_contextual_masses(&PopulatedTransaction::new(&estimate,entries.to_vec())).ok_or_else(||bad("storage mass unavailable"))?;
    let cf=MAINNET_PARAMS.block_mass_cofactors();
    let effective=non.compute_mass.max((non.transient_mass as f64*cf.transient).ceil() as u64).max((ctx.storage_mass as f64*cf.storage).ceil() as u64);
    if non.compute_mass>500_000||non.transient_mass>1_000_000||ctx.storage_mass>100_000||fee<effective.saturating_mul(100){return Err(bad("order exceeds network mass limits or needs a higher network fee; nothing was signed"));}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_consensus_core::{
        subnets::SUBNETWORK_ID_NATIVE,
        tx::{CovenantBinding, TransactionInput, TransactionOutpoint, TransactionOutput},
    };
    fn fixture(sell: bool) -> (String, PsktRequest) {
        let secret = format!("private:{}", "01".repeat(32));
        let mut address = crate::derive_address(&secret).unwrap();
        address.prefix = Prefix::Testnet;
        let owner = hex::encode(&address.payload);
        let cid = "aa".repeat(32);
        let market = "bb".repeat(32);
        let mut st = serde_json::json!({"owner":owner,"market":market,"kcc20":cid,"expiryDaa":1036000,"refundFee":1000000});
        if sell {
            st["amount"] = 1000.into();
            st["tip"] = 5000000.into();
            st["minSompi"] = 100000000.into();
            st["refundGuard"] = Value::String("00".repeat(32));
        } else {
            for (k, v) in [
                ("creatorBps", 50),
                ("feeBps", 100),
                ("feeMin", 20000000),
                ("tokenDust", 100000000),
                ("unitsIn", 970),
                ("minTokens", 1000),
            ] {
                st[k] = serde_json::json!(v);
            }
            st["templateHash"] = templates()["ForgeBuyOrder"]["templateHash"].clone();
        }
        let t = templates();
        let mut program = vec![];
        if sell {
            for p in t["ForgeSellOrder"]["parts"].as_array().unwrap() {
                if let Some(h) = p["hex"].as_str() {
                    program.extend(bytes(h).unwrap());
                    continue;
                }
                let f = match p["slot"].as_str().unwrap() {
                    "marketCovid" => "market",
                    "kcc20Covid" => "kcc20",
                    "tipSompi" => "tip",
                    x => x,
                };
                if p["kind"] == "bytes32" {
                    program.extend(push(&bytes(st[f].as_str().unwrap()).unwrap()).unwrap());
                } else {
                    program.extend(
                        ScriptBuilder::new()
                            .add_i64(st[f].as_i64().unwrap())
                            .unwrap()
                            .drain(),
                    );
                }
            }
        } else {
            program.push(0x6b);
            for f in ["owner", "market", "kcc20"] {
                program.extend(push(&bytes(st[f].as_str().unwrap()).unwrap()).unwrap());
            }
            for f in ["unitsIn", "minTokens", "expiryDaa"] {
                program.push(8);
                program.extend(st[f].as_u64().unwrap().to_le_bytes());
            }
            program.extend(bytes(t["ForgeBuyOrder"]["suffix"].as_str().unwrap()).unwrap());
        }
        let spk = pay_to_script_hash_script(&program);
        let order_address = Address::new(
            Prefix::Testnet,
            Version::ScriptHash,
            &bytes(&hash(&program)).unwrap(),
        )
        .to_string();
        let coin_value = if sell { 100000000 } else { 1099850000 };
        let mut order = serde_json::json!({"state":st,"redeemScript":hex::encode(&program),"scriptHash":hash(&program),"address":order_address,"output":{"sompi":coin_value,"index":if sell{2}else{0}}});
        let wallet = pay_to_address_script(&address);
        let mut inputs = vec![];
        let mut entries = vec![];
        let mut outs = vec![];
        let mut input_redeems = serde_json::json!({});
        let mut output_redeems = serde_json::json!({});
        let mut scripts = serde_json::json!([]);
        if sell {
            let old = Note {
                amount: 2000,
                owner: address.payload.to_vec(),
                scheme: 0,
                borrow: 0,
                guard: vec![0; 32],
            };
            let sold = Note {
                amount: 1000,
                owner: bytes(&hash(&program)).unwrap(),
                scheme: 3,
                ..old.clone()
            };
            let change = Note {
                amount: 1000,
                ..old.clone()
            };
            let next = vec![sold.clone(), change.clone()];
            let old_script = note_program(&old).unwrap();
            let (_, slot) = witness(&next, &old_script, true, false).unwrap();
            inputs.push(TransactionInput::new_with_compute_budget(
                TransactionOutpoint::new("11".repeat(32).parse().unwrap(), 0),
                vec![],
                0,
                150,
            ));
            entries.push(UtxoEntry::new(
                100000000,
                pay_to_script_hash_script(&old_script),
                100,
                false,
                Some(cid.parse().unwrap()),
            ));
            input_redeems["0"] = hex::encode(&old_script).into();
            for (i, n) in next.iter().enumerate() {
                let p = note_program(n).unwrap();
                output_redeems[i.to_string()] = hex::encode(&p).into();
                outs.push(TransactionOutput::with_covenant(
                    100000000,
                    pay_to_script_hash_script(&p),
                    Some(CovenantBinding::new(0, cid.parse().unwrap())),
                ));
            }
            let _ = slot;
            scripts = serde_json::json!([{"inputIndex":0,"scriptHex":hex::encode(&old_script),"signType":1,"signatureScript":token_signature_template(&next,true)}]);
        }
        inputs.push(TransactionInput::new_with_compute_budget(
            TransactionOutpoint::new("22".repeat(32).parse().unwrap(), 0),
            vec![],
            0,
            11,
        ));
        entries.push(UtxoEntry::new(
            4_000_000_000,
            wallet.clone(),
            100,
            false,
            None,
        ));
        outs.push(TransactionOutput::new(coin_value, spk));
        outs.push(TransactionOutput::new(
            if sell { 3_791_000_000 } else { 2_899_150_000 },
            wallet,
        ));
        let tx = Transaction::new(1, inputs, outs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        let oi = if sell { 2 } else { 0 };
        order["output"]["outpoint"] = format!("{}:{oi}", tx.id()).into();
        if sell {
            order["tokens"] = serde_json::json!({"redeemScript":output_redeems["0"],"output":{"index":0,"sompi":100000000,"outpoint":format!("{}:0",tx.id())}});
        }
        let raw: Value =
            serde_json::from_str(&crate::kcc20::wrpc_safe_json(&tx, &entries).unwrap()).unwrap();
        let request=serde_json::from_value(serde_json::json!({"sender":address.to_string(),"profile":"kasforge-tn10-order-v1","txJsonString":raw.to_string(),"signInputs":(0..tx.inputs.len()).map(|i|serde_json::json!({"index":i,"sighashType":1})).collect::<Vec<_>>(),"scripts":scripts,"tradeSummary":{"order":order,"tokenId":cid,"marketId":market,"action":if sell{"order-sell"}else{"order-buy"},"chainDaa":"1000000","secondChainDaa":"1000000","amount":if sell{"1000"}else{"1000000000"},"maximumDebit":"1101000000","minimumOut":if sell{"100000000"}else{"1000"},"inputRedeems":input_redeems,"outputRedeems":output_redeems}})).unwrap();
        (secret, request)
    }
    #[test]
    fn synthetic_buy_and_sell_sign_and_execute_locally() {
        for sell in [false, true] {
            let (secret, r) = fixture(sell);
            let review = crate::prepare_pskt(&r).unwrap();
            let signed = crate::sign_pskt(&secret, &r, &review.review_hash);
            assert!(signed.is_ok(), "{sell}: {signed:?}");
            if let Ok(directory) = std::env::var("KASPIRE_FORGE_SYNTHETIC_OUT") {
                // Explicit opt-in test artifact: synthetic outpoints and
                // public signed transactions only. Never export the secret.
                let output = serde_json::json!({
                    "request": r, "review": review, "signed": signed.unwrap()
                });
                std::fs::write(
                    std::path::Path::new(&directory)
                        .join(if sell { "sell.json" } else { "buy.json" }),
                    serde_json::to_vec(&output).unwrap(),
                )
                .unwrap();
            }
        }
    }
    #[test]
    fn order_terms_output_and_review_mutations_fail() {
        for sell in [false, true] {
            let (secret, r) = fixture(sell);
            let review = crate::prepare_pskt(&r).unwrap();
            for field in ["owner", "market", "kcc20"] {
                let mut other = r.clone();
                other.trade_summary.as_mut().unwrap()["order"]["state"][field] =
                    Value::String("cc".repeat(32));
                assert!(crate::prepare_pskt(&other).is_err());
            }
            let mut other = r.clone();
            other.trade_summary.as_mut().unwrap()["minimumOut"] = serde_json::json!("900000000000");
            assert!(crate::prepare_pskt(&other).is_err());
            assert!(crate::sign_pskt(&secret, &r, &"00".repeat(32)).is_err());
            assert!(crate::sign_pskt(&secret, &r, &review.review_hash).is_ok());
        }
    }
    #[test]
    fn saved_buy_and_sell_orders_cancel_without_the_forge_server() {
        for sell in [false, true] {
            let (secret, source) = fixture(sell);
            let summary = source.trade_summary.as_ref().unwrap();
            let order = &summary["order"];
            let program = bytes(text(order, "redeemScript").unwrap()).unwrap();
            let mut address = crate::derive_address(&secret).unwrap();
            address.prefix = Prefix::Testnet;
            let txid = crate::prepare_pskt(&source)
                .unwrap()
                .transaction_id
                .parse()
                .unwrap();
            let mut inputs = vec![];
            let mut outputs = vec![];
            let mut entries = vec![];
            let mut ir = serde_json::json!({});
            let mut or = serde_json::json!({});
            if sell {
                let old = Note {
                    amount: 1000,
                    owner: bytes(text(order, "scriptHash").unwrap()).unwrap(),
                    scheme: 3,
                    borrow: 0,
                    guard: vec![0; 32],
                };
                let back = Note {
                    owner: address.payload.to_vec(),
                    scheme: 0,
                    ..old.clone()
                };
                let old_script = note_program(&old).unwrap();
                let (w, _) = witness(&[back.clone()], &old_script, true, true).unwrap();
                inputs.push(TransactionInput::new_with_compute_budget(
                    TransactionOutpoint::new(txid, 0),
                    w,
                    0,
                    150,
                ));
                entries.push(UtxoEntry::new(
                    100000000,
                    pay_to_script_hash_script(&old_script),
                    100,
                    false,
                    Some(text(&order["state"], "kcc20").unwrap().parse().unwrap()),
                ));
                let next = note_program(&back).unwrap();
                outputs.push(TransactionOutput::with_covenant(
                    100000000,
                    pay_to_script_hash_script(&next),
                    Some(CovenantBinding::new(
                        0,
                        text(&order["state"], "kcc20").unwrap().parse().unwrap(),
                    )),
                ));
                ir["0"] = hex::encode(old_script).into();
                or["0"] = hex::encode(next).into();
            }
            let ci = inputs.len();
            let value = num(&order["output"], "sompi").unwrap();
            inputs.push(TransactionInput::new_with_compute_budget(
                TransactionOutpoint::new(txid, num(&order["output"], "index").unwrap() as u32),
                vec![],
                0,
                50,
            ));
            entries.push(UtxoEntry::new(
                value,
                pay_to_script_hash_script(&program),
                100,
                false,
                None,
            ));
            outputs.push(TransactionOutput::new(
                value - 10000000,
                pay_to_address_script(&address),
            ));
            let tx = Transaction::new(1, inputs, outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
            let raw = crate::kcc20::wrpc_safe_json(&tx, &entries).unwrap();
            let r:PsktRequest=serde_json::from_value(serde_json::json!({"sender":address.to_string(),"profile":"kasforge-tn10-order-v1","txJsonString":raw,"signInputs":[{"index":ci,"sighashType":1}],"scripts":[{"inputIndex":ci,"scriptHex":hex::encode(program),"signType":1,"signatureScript":{"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"a0893109"}]}}],"tradeSummary":{"action":"cancel","order":order,"tokenId":order["state"]["kcc20"],"marketId":order["state"]["market"],"inputRedeems":ir,"outputRedeems":or}})).unwrap();
            let review = crate::prepare_pskt(&r).unwrap();
            let result = crate::sign_pskt(&secret, &r, &review.review_hash);
            assert!(result.is_ok(), "{sell} cancellation: {result:?}");
        }
    }
}
