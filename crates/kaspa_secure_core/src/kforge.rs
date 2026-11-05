//! KForge (NOT KasForge): atomic v6 curve/pool swaps. Programs were
//! compiled from the partner sources and matched byte-for-byte against chain
//! commitments. Registry assertions are metadata, never signing authority.
use crate::pskt::{
    PsktRequest, PsktScriptArgument as Arg, PsktScriptInput, PsktSignatureScriptMode,
    PsktSignatureScriptTemplate,
};
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_txscript::{
    pay_to_address_script, pay_to_script_hash_script, script_builder::ScriptBuilder,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

const CELL: u64 = 90_000_000;
const LOT: u64 = 1_000_000;
const SUPPLY: u64 = 1_000_000_000;
fn bad(s: &str) -> CoreError {
    CoreError::InvalidRequest(format!("KForge: {s}"))
}
fn check(ok: bool, s: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(bad(s)) }
}
fn num(v: &Value) -> Result<u64> {
    let s = v
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| v.to_string());
    check(
        !s.is_empty() && s.len() <= 19 && s.bytes().all(|b| b.is_ascii_digit()),
        "invalid integer",
    )?;
    s.parse::<u64>()
        .ok()
        .filter(|v| *v < 1u64 << 62)
        .ok_or_else(|| bad("integer overflow"))
}
fn bytes(v: &Value) -> Result<Vec<u8>> {
    hex::decode(v.as_str().ok_or_else(|| bad("missing hex"))?).map_err(|_| bad("invalid hex"))
}
fn cid(v: &Value) -> Result<String> {
    let b = bytes(v)?;
    check(b.len() == 32, "invalid covenant ID")?;
    Ok(hex::encode(b))
}
fn add(a: u64, b: u64) -> Result<u64> {
    a.checked_add(b)
        .filter(|n| *n < 1u64 << 62)
        .ok_or_else(|| bad("arithmetic overflow"))
}
fn sub(a: u64, b: u64) -> Result<u64> {
    a.checked_sub(b).ok_or_else(|| bad("negative amount"))
}
fn product(a: u64, b: u64, d: u64) -> Result<u64> {
    check(d > 0, "zero reserve")?;
    u64::try_from(a as u128 * b as u128 / d as u128).map_err(|_| bad("arithmetic overflow"))
}
fn pins() -> Value {
    serde_json::from_str(include_str!("kforge_templates.json")).expect("pinned KForge programs")
}
fn venue_pins(mainnet: bool) -> Value {
    if mainnet {
        serde_json::from_str(include_str!("kforge_mainnet_templates.json"))
            .expect("pinned KForge Mainnet programs")
    } else { pins() }
}
fn packed(program: &[u8]) -> String {
    let s = pay_to_script_hash_script(program);
    format!("{:04x}{}", s.version(), hex::encode(s.script()))
}
fn template_hash(p: &[u8], state_start: usize, state_len: usize) -> Result<Vec<u8>> {
    check(state_start + state_len <= p.len(), "state boundary")?;
    let a = &p[..state_start];
    let b = &p[state_start + state_len..];
    let mut input = (a.len() as u64).to_le_bytes().to_vec();
    input.extend(a);
    input.extend((b.len() as u64).to_le_bytes());
    input.extend(b);
    Ok(kaspa_hashes::blake2b_simd::Params::new()
        .hash_length(32)
        .hash(&input)
        .as_bytes()
        .to_vec())
}
fn materialize(t: &Value, fields: &HashMap<&str, Vec<u8>>) -> Result<Vec<u8>> {
    let mut p = bytes(&t["bytecode"])?;
    for (name, slot) in t["slots"].as_object().ok_or_else(|| bad("program slots"))? {
        let b = fields
            .get(name.as_str())
            .ok_or_else(|| bad("missing constructor field"))?;
        check(
            b.len() == num(&slot["length"])? as usize,
            "constructor width",
        )?;
        for off in slot["offsets"]
            .as_array()
            .ok_or_else(|| bad("program offsets"))?
        {
            let offset = num(off)? as usize;
            check(offset + b.len() <= p.len(), "constructor offset")?;
            p[offset..offset + b.len()].copy_from_slice(b);
        }
    }
    Ok(p)
}
fn venue_program(t: &Value, state: &Value, pool: bool, mainnet: bool) -> Result<Vec<u8>> {
    let p = venue_pins(mainnet);
    let creator = bytes(&t["creator"])?;
    let p2sh = mainnet && creator.len() == 37
        && creator[..4] == [0,0,0xaa,32] && creator[36] == 0x87;
    check(
        p2sh || (creator.len() == 36 && creator[..3] == [0, 0, 32] && creator[35] == 0xac),
        "unsupported creator script",
    )?;
    let token = bytes(&t["tokenCovId"])?;
    check(token.len() == 32, "token ID")?;
    let mut f = HashMap::from([("creator", creator), ("token", token)]);
    for field in ["fees", "vault"] {
        let key = if field == "fees" {
            "feesOwed"
        } else {
            "vaultOwed"
        };
        f.insert(field, num(&state[key])?.to_le_bytes().to_vec());
    }
    if pool {
        f.insert("kas", num(&state["kasReserve"])?.to_le_bytes().to_vec());
        f.insert(
            "tokens",
            num(&state["tokenReserve"])?.to_le_bytes().to_vec(),
        );
        materialize(&p[if p2sh {"poolP2shCreator"} else {"pool"}], &f)
    } else {
        f.insert("sold", num(&state["sold"])?.to_le_bytes().to_vec());
        let zero = json!({"kasReserve":0,"tokenReserve":350000000,"feesOwed":0,"vaultOwed":0});
        let pp = venue_program(t, &zero, true, mainnet)?;
        f.insert("poolHash", template_hash(&pp, 1, 69)?);
        materialize(&p[if p2sh {"curveP2shCreator"} else {"curve"}], &f)
    }
}
#[derive(Clone)]
struct Note {
    amount: u64,
    owner: Vec<u8>,
    scheme: u8,
    borrow: u8,
    threshold: u64,
}
impl Note {
    fn program(&self) -> Result<Vec<u8>> {
        check(
            self.amount <= SUPPLY
                && self.owner.len() == 32
                && (self.scheme == 0 || self.scheme == 4)
                && self.borrow <= 1,
            "invalid token state",
        )?;
        let t = pins();
        let mut p = bytes(&t["token"]["prefix"])?;
        p.push(8);
        p.extend(self.amount.to_le_bytes());
        p.push(32);
        p.extend(&self.owner);
        p.extend([1, self.scheme, 1, self.borrow, 32]);
        p.extend(self.threshold.to_le_bytes());
        p.extend([0; 24]);
        p.push(32);
        p.extend([0; 32]);
        p.extend(bytes(&t["token"]["suffix"])?);
        Ok(p)
    }
}
fn columns(notes: &[Note]) -> Vec<Vec<u8>> {
    vec![
        notes.iter().flat_map(|n| n.amount.to_le_bytes()).collect(),
        notes.iter().flat_map(|n| n.owner.clone()).collect(),
        notes.iter().map(|n| n.scheme).collect(),
        notes.iter().map(|n| n.borrow).collect(),
        notes
            .iter()
            .flat_map(|n| [n.threshold.to_le_bytes().to_vec(), vec![0; 24]].concat())
            .collect(),
        vec![0; 32 * notes.len()],
    ]
}
fn witness(data: &[Vec<u8>], selector: Option<i64>, program: &[u8]) -> Result<String> {
    let mut b = ScriptBuilder::new();
    for d in data {
        b.add_data(d).map_err(|_| bad("witness push"))?;
    }
    if let Some(n) = selector {
        b.add_i64(n).map_err(|_| bad("selector"))?;
    }
    b.add_data(program).map_err(|_| bad("redeem push"))?;
    Ok(hex::encode(b.drain()))
}
fn binding(o: &Value, id: &str, leader: usize) -> Result<()> {
    check(
        o["covenant"]["covenantId"] == id
            && num(&o["covenant"]["authorizingInput"])? == leader as u64,
        "wrong output covenant/authority",
    )
}
fn verify_note_input(i: &Value, amount: u64, owner: Vec<u8>, scheme: u8) -> Result<Note> {
    for borrow in 0..=if scheme == 0 { 1 } else { 0 } {
        for threshold in if borrow == 1 {
            vec![0, LOT - 1, amount.saturating_sub(1)]
        } else {
            vec![0]
        } {
            let n = Note {
                amount,
                owner: owner.clone(),
                scheme,
                borrow,
                threshold,
            };
            if i["utxo"]["scriptPublicKey"] == packed(&n.program()?) {
                return Ok(n);
            }
        }
    }
    Err(bad(
        "token input differs from verified template, amount, owner or supported receive policy",
    ))
}
/// Expand ONLY this strict profile. All contract witnesses are rebuilt locally;
/// no caller-provided marker, program or prebuilt witness can bypass this path.
pub(crate) fn expand(r: &PsktRequest) -> Result<PsktRequest> {
    let (mainnet, network, prefix, base, slope) = match r.profile.as_deref() {
        Some("kforge-mainnet-swap-v1") => (true, "mainnet", Prefix::Mainnet, 6_249_997_720u128, 15_644_550u128),
        Some("kforge-tn10-swap-v1") => (false, "testnet-10", Prefix::Testnet, 624_999_772u128, 1_564_455u128),
        _ => return Err(bad("unsupported signing profile")),
    };
    check(r.tx_json_string.len() <= 128 * 1024, "transaction exceeds safety limit")?;
    check(serde_json::to_vec(&r.trade_summary).map_err(|_|bad("trade summary"))?.len() <= 48 * 1024, "trade summary exceeds safety limit")?;
    let addr = Address::try_from(r.sender.as_str()).map_err(|_| bad("invalid sender"))?;
    check(
        addr.prefix == prefix
            && addr.version == Version::PubKey
            && addr.payload.len() == 32,
        "Schnorr wallet on the selected KForge network required",
    )?;
    check(
        r.scripts.is_empty()
            && r.sign_inputs.len() == 1
            && r.sign_inputs[0].sighash_type == 1
            && r.sign_inputs[0].expected_sighash.is_some(),
        "one SIGHASH_ALL wallet signature required",
    )?;
    let summary = r
        .trade_summary
        .as_ref()
        .ok_or_else(|| bad("missing selected trade"))?;
    check(summary["network"] == network, "wrong network")?;
    let t = &summary["market"];
    check(num(&t["base"])? as u128 == base && num(&t["slope"])? as u128 == slope
        && num(&t["curveSupply"])? == 650, "wrong network curve parameters")?;
    let token = cid(&t["tokenCovId"])?;
    let pool = t["phase"] == "pool";
    check(pool || t["phase"] == "curve", "unsupported venue")?;
    let market = cid(if pool {
        &t["pool"]["poolCovId"]
    } else {
        &t["rungCovId"]
    })?;
    check(
        r.token_id.as_deref() == Some(&token) && r.lp_covenant_id.as_deref() == Some(&market),
        "selected covenant differs",
    )?;
    let buy = r.side.as_deref() == Some("buy");
    check(
        buy || r.side.as_deref() == Some("sell"),
        "unsupported action",
    )?;
    let amount = num(&summary["amount"])?;
    check(amount > 0, "empty trade")?;
    let mut tx: Value =
        serde_json::from_str(&r.tx_json_string).map_err(|_| bad("transaction JSON"))?;
    check(
        tx["version"] == 1
            && num(&tx["lockTime"])? == 0
            && num(&tx["gas"])? == 0
            && tx["payload"] == ""
            && tx["subnetworkId"] == "0000000000000000000000000000000000000000"
            && num(&tx["storageMass"])? == 0,
        "unexpected transaction header",
    )?;
    let ins = tx["inputs"]
        .as_array()
        .ok_or_else(|| bad("inputs"))?
        .clone();
    let outs = tx["outputs"]
        .as_array()
        .ok_or_else(|| bad("outputs"))?
        .clone();
    check(
        (3..=4).contains(&ins.len()) && (3..=5).contains(&outs.len()),
        "unsupported trade shape",
    )?;
    let wallet = pay_to_address_script(&addr);
    let wallet_hex = format!("{:04x}{}", wallet.version(), hex::encode(wallet.script()));
    let owner = addr.payload.to_vec();
    let market_owner = bytes(&json!(market))?;
    let state = if pool { &t["pool"] } else { t };
    let fees = num(&state["feesOwed"])?;
    let vault = num(&state["vaultOwed"])?;
    let mut next = state.clone();
    let old_reserve;
    let new_reserve;
    let tokens;
    let market_kas;
    let fee;
    if pool {
        let k = num(&state["kasReserve"])?;
        let tok = num(&state["tokenReserve"])?;
        check(
            k >= 100_000_000_000 && tok > 0 && tok <= SUPPLY,
            "invalid pool reserves",
        )?;
        old_reserve = tok;
        if buy {
            market_kas = amount;
            fee = amount / 100;
            tokens = product(amount, tok, add(k, amount)?)?;
            next["kasReserve"] = json!(add(k, amount)?);
            new_reserve = sub(tok, tokens)?;
        } else {
            tokens = amount;
            let gross = product(k, tokens, add(tok, tokens)?)?;
            fee = gross / 100;
            market_kas = sub(gross, fee)?;
            let nk = sub(k, gross)?;
            check(nk >= 100_000_000_000, "pool minimum reserve")?;
            next["kasReserve"] = json!(nk);
            new_reserve = add(tok, tokens)?;
        }
        next["tokenReserve"] = json!(new_reserve);
        check(
            num(&ins[0]["utxo"]["amount"])? == add(add(k, fees)?, vault)?,
            "pool KAS accounting",
        )?;
    } else {
        let sold = num(&state["sold"])?;
        check(sold <= 650 && amount <= 650, "invalid curve quantity")?;
        old_reserve = (1000 - sold) * LOT;
        let start = if buy { sold } else { sub(sold, amount)? };
        let ns = if buy { add(sold, amount)? } else { start };
        check(ns <= 650, "curve graduation requires a new pool quote")?;
        let total = amount as u128 * base
            + slope
                * (start as u128 * amount as u128 + amount as u128 * (amount - 1) as u128 / 2);
        let value = u64::try_from(total).map_err(|_| bad("curve overflow"))?;
        let released = if buy { value } else { value - value / 100 };
        fee = released / 100;
        market_kas = if buy { value } else { released - fee };
        tokens = amount * LOT - if buy { amount / 100 * LOT } else { 0 };
        new_reserve = (1000 - ns) * LOT;
        next["sold"] = json!(ns);
    }
    check(
        tokens > 0 && tokens <= SUPPLY,
        "empty or excessive token amount",
    )?;
    let buy_budget = if buy {
        let budget = num(&summary["buyBudgetSompi"])?;
        check(budget > 0 && budget <= 4_500_000_000_000_000, "invalid KAS buy budget")?;
        check(market_kas <= budget, "trade exceeds the entered KAS amount")?;
        if pool {
            check(market_kas == budget, "pool input differs from the entered KAS amount")?;
        } else {
            let sold = num(&state["sold"])?;
            if sold + amount < 650 {
                let next_price = base + slope * (sold + amount) as u128;
                check(((budget - market_kas) as u128) < next_price,
                    "curve quantity does not use the entered KAS trade budget")?;
            }
        }
        Some(budget)
    } else { None };
    next["feesOwed"] = json!(add(fees, fee - fee / 10)?);
    next["vaultOwed"] = json!(add(vault, fee / 10)?);
    let old_venue = venue_program(t, state, pool, mainnet)?;
    let new_venue = venue_program(t, &next, pool, mainnet)?;
    check(
        ins[0]["utxo"]["covenantId"] == market
            && ins[0]["utxo"]["scriptPublicKey"] == packed(&old_venue),
        "venue state/program does not match input",
    )?;
    binding(&outs[0], &market, 0)?;
    check(
        outs[0]["scriptPublicKey"] == packed(&new_venue),
        "venue successor differs",
    )?;
    let venue_value = num(&ins[0]["utxo"]["amount"])?;
    let delta = if pool && buy {
        add(market_kas, fee)?
    } else {
        market_kas
    };
    check(
        num(&outs[0]["value"])?
            == if buy {
                add(venue_value, delta)?
            } else {
                sub(venue_value, delta)?
            },
        "venue value differs from independently calculated trade",
    )?;
    let has_own = if buy { ins.len() == 4 } else { true };
    let reserve_index = if has_own { 2 } else { 1 };
    let leader = 1usize;
    let selected = if buy { ins.len() - 1 } else { 1 };
    check(
        r.sign_inputs[0].index == selected
            && (!buy || selected == reserve_index + 1)
            && (buy || ins.len() == 3),
        "unexpected wallet input",
    )?;
    let mut notes_in: Vec<(usize, Note)> = Vec::new();
    let mut old_own = 0;
    let mut own_cell = 0;
    if has_own {
        old_own = if buy {
            num(&summary["existingAmount"])?
        } else {
            add(num(&summary["leftover"])?, tokens)?
        };
        let note = verify_note_input(&ins[1], old_own, owner.clone(), 0)?;
        check(
            !buy || (note.borrow == 1 && tokens > note.threshold),
            "existing recipient cell does not permit this Borrowed Receive increase",
        )?;
        own_cell = num(&ins[1]["utxo"]["amount"])?;
        check(own_cell >= CELL, "insufficient own token reserve")?;
        notes_in.push((1, note));
    }
    let reserve = verify_note_input(&ins[reserve_index], old_reserve, market_owner.clone(), 4)?;
    check(
        num(&ins[reserve_index]["utxo"]["amount"])? == CELL,
        "unexpected venue token-cell reserve",
    )?;
    notes_in.push((reserve_index, reserve));
    let mut expected: Vec<(usize, Note, u64)> = Vec::new();
    if buy {
        let receive = verify_note_input(
            &json!({"utxo":{"scriptPublicKey":outs[1]["scriptPublicKey"]}}),
            add(old_own, tokens)?,
            owner.clone(),
            0,
        )?;
        if has_own {
            check(
                receive.borrow == notes_in[0].1.borrow
                    && receive.threshold == notes_in[0].1.threshold,
                "borrowed receiver policy changed",
            )?;
        }
        expected.push((1, receive, if has_own { own_cell } else { CELL }));
        if !pool {
            expected.push((
                2,
                Note {
                    amount: amount / 100 * LOT,
                    owner: vec![0; 32],
                    scheme: 0,
                    borrow: 0,
                    threshold: 0,
                },
                CELL,
            ));
        }
        expected.push((
            if pool { 2 } else { 3 },
            Note {
                amount: new_reserve,
                owner: market_owner,
                scheme: 4,
                borrow: 0,
                threshold: 0,
            },
            CELL,
        ));
        check(outs.len() == expected.len() + 2, "unexpected buy outputs")?;
        check(
            ins[selected]["utxo"]["scriptPublicKey"] == wallet_hex
                && ins[selected]["utxo"]["covenantId"].is_null(),
            "funding input is not wallet owned",
        )?;
    } else {
        expected.push((
            2,
            Note {
                amount: new_reserve,
                owner: market_owner,
                scheme: 4,
                borrow: 0,
                threshold: 0,
            },
            CELL,
        ));
        let remain = sub(old_own, tokens)?;
        if remain > 0 {
            let change = verify_note_input(
                &json!({"utxo":{"scriptPublicKey":outs[3]["scriptPublicKey"]}}),
                remain,
                owner.clone(),
                0,
            )?;
            expected.push((3, change, own_cell));
        }
        check(outs.len() == expected.len() + 2, "unexpected sell outputs")?;
    }
    let mut new_notes = Vec::new();
    for (index, n, value) in &expected {
        binding(&outs[*index], &token, leader)?;
        check(
            outs[*index]["scriptPublicKey"] == packed(&n.program()?)
                && num(&outs[*index]["value"])? == *value,
            "token output amount, owner, policy or reserve differs",
        )?;
        new_notes.push(n.clone());
    }
    let plain_index = if buy { outs.len() - 1 } else { 1 };
    check(
        outs[plain_index]["scriptPublicKey"] == wallet_hex
            && outs[plain_index]["covenant"].is_null(),
        "foreign KAS payout/change",
    )?;
    let mut total_in = 0;
    let mut total_out = 0;
    let mut seen = HashSet::new();
    for (i, input) in ins.iter().enumerate() {
        check(
            input["signatureScript"] == ""
                && num(&input["sequence"])? == 0
                && input["utxo"]["isCoinbase"] == false,
            "pre-signed or unsupported input",
        )?;
        let id = cid(&input["transactionId"])?;
        let index = num(&input["index"])?;
        check(
            index <= u32::MAX as u64 && seen.insert((id, index)),
            "duplicate/invalid input",
        )?;
        let budget = num(&input["computeBudget"])?;
        check((1..=50).contains(&budget), "excessive compute budget")?;
        if i != 0 && i != selected || (!buy && i == selected) {
            check(
                input["utxo"]["covenantId"] == token,
                "unexpected token covenant",
            )?;
        }
        total_in = add(total_in, num(&input["utxo"]["amount"])?)?;
    }
    for o in &outs {
        total_out = add(total_out, num(&o["value"])?)?;
    }
    let network = sub(total_in, total_out)?;
    check(
        network > 0 && network <= 100_000_000,
        "network fee exceeds 1 KAS safety cap",
    )?;
    if !buy {
        check(
            network <= 40_000_000,
            "sale network fee exceeds contract allowance",
        )?;
    }
    let wallet_net = if buy {
        sub(
            num(&ins[selected]["utxo"]["amount"])?,
            num(&outs[plain_index]["value"])?,
        )?
    } else {
        num(&outs[1]["value"])?
    };
    if buy {
        check(
            wallet_net <= num(&summary["maximumDebit"])? && tokens >= num(&summary["minimumOut"])?,
            "buy exceeds approved limits",
        )?;
    } else {
        check(
            wallet_net >= num(&summary["minimumOut"])?,
            "sale below approved minimum",
        )?;
    }
    // Every token continuation is included in CID order, including zero burn.
    let cols = columns(&new_notes);
    let pins = pins();
    let prefix = bytes(&pins["token"]["prefix"])?;
    let suffix = bytes(&pins["token"]["suffix"])?;
    let mut args = Vec::new();
    if pool {
        for key in ["kasReserve", "tokenReserve"] {
            args.push(num(&next[key])?.to_le_bytes().to_vec());
        }
        args.push(bytes(&t["tokenCovId"])?);
        for key in ["feesOwed", "vaultOwed"] {
            args.push(num(&next[key])?.to_le_bytes().to_vec());
        }
        // Script numbers, not fixed-width state vectors.
        let mut b = ScriptBuilder::new();
        for d in &args {
            b.add_data(d).map_err(|_| bad("state witness"))?;
        }
        for v in [
            if buy { 0 } else { 1 },
            if buy { 0 } else { market_kas },
            if buy { tokens } else { 0 },
        ] {
            b.add_i64(v as i64).map_err(|_| bad("swap limits"))?;
        }
        for d in [&prefix, &suffix] {
            b.add_data(d).map_err(|_| bad("template witness"))?;
        }
        b.add_i64(0).map_err(|_| bad("swap selector"))?;
        b.add_data(&old_venue).map_err(|_| bad("venue redeem"))?;
        tx["inputs"][0]["signatureScript"] = json!(hex::encode(b.drain()));
    } else {
        for key in ["sold", "feesOwed", "vaultOwed"] {
            args.push(num(&next[key])?.to_le_bytes().to_vec());
        }
        let mut b = ScriptBuilder::new();
        for d in &args {
            b.add_data(d).map_err(|_| bad("state witness"))?;
        }
        b.add_i64(amount as i64)
            .map_err(|_| bad("quantity witness"))?;
        for d in [&prefix, &suffix] {
            b.add_data(d).map_err(|_| bad("template witness"))?;
        }
        b.add_i64(if buy { 0 } else { 2 })
            .map_err(|_| bad("curve selector"))?;
        b.add_data(&old_venue).map_err(|_| bad("venue redeem"))?;
        tx["inputs"][0]["signatureScript"] = json!(hex::encode(b.drain()));
    }
    let mut expanded = r.clone();
    for (idx, n) in notes_in {
        let leader = idx == 1;
        let program = n.program()?;
        let tag = hex::decode(if leader { "79c71c23" } else { "fd3ef14a" }).unwrap();
        let mut a = if leader { cols.clone() } else { Vec::new() };
        if idx == selected {
            let mut args = a
                .into_iter()
                .map(|b| Arg::Data {
                    hex: hex::encode(b),
                })
                .collect::<Vec<_>>();
            args.push(Arg::Signature {
                prefix_hex: if leader { "00" } else { "" }.into(),
            });
            args.push(Arg::Data {
                hex: hex::encode(tag),
            });
            expanded.scripts.push(PsktScriptInput {
                input_index: idx,
                script_hex: hex::encode(program),
                sign_type: Some(1),
                signature_script: Some(PsktSignatureScriptTemplate {
                    mode: PsktSignatureScriptMode::OrderedArgs,
                    args,
                }),
                prebuilt_signature_script: None,
                signature_offsets: Vec::new(),
                expected_sighash: None,
            });
        } else {
            a.push(if leader {
                vec![if n.scheme == 0 { 1 } else { 0 }]
            } else {
                vec![]
            });
            a.push(tag);
            tx["inputs"][idx]["signatureScript"] = json!(witness(&a, None, &program)?);
        }
    }
    let mut terms = summary.clone();
    terms["verified"] = json!({"network":if mainnet{"mainnet"}else{"testnet-10"},"venue":if pool{"pool"}else{"curve"},"tokens":tokens.to_string(),"marketKas":market_kas.to_string(),"protocolFee":fee.to_string(),"networkFee":network.to_string(),"walletNet":wallet_net.to_string(),"cellReserveChange":if buy{wallet_net as i128-market_kas as i128-(if pool{fee}else{0}) as i128-network as i128}else{wallet_net as i128-market_kas as i128+network as i128}});
    if let Some(budget) = buy_budget {
        terms["verified"]["buyBudgetSompi"] = json!(budget.to_string());
        terms["verified"]["unspentBudgetSompi"] = json!((budget - market_kas).to_string());
    }
    expanded.trade_summary = Some(terms);
    expanded.tx_json_string = serde_json::to_string(&tx).map_err(|_| bad("expanded JSON"))?;
    Ok(expanded)
}

pub(crate) fn commit_storage_mass(
    tx: &kaspa_consensus_core::tx::Transaction,
    entries: &[kaspa_consensus_core::tx::UtxoEntry],
) -> Result<()> {
    use kaspa_consensus_core::{
        config::params::MAINNET_PARAMS, mass::MassCalculator, tx::PopulatedTransaction,
    };
    let mass = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS)
        .calc_contextual_masses(&PopulatedTransaction::new(tx, entries.to_vec()))
        .ok_or_else(|| bad("storage commitment unavailable"))?
        .storage_mass;
    tx.set_storage_mass(mass);
    Ok(())
}

pub(crate) fn validate_mass(
    tx: &kaspa_consensus_core::tx::Transaction,
    entries: &[kaspa_consensus_core::tx::UtxoEntry],
    r: &PsktRequest,
) -> Result<()> {
    use kaspa_consensus_core::{
        config::params::MAINNET_PARAMS, mass::MassCalculator, tx::PopulatedTransaction,
    };
    let mut estimate = tx.clone();
    estimate.set_storage_mass(0);
    let selected = r.sign_inputs[0].index;
    let mut b = ScriptBuilder::new();
    if let Some(script) = r.scripts.first() {
        for arg in &script
            .signature_script
            .as_ref()
            .ok_or_else(|| bad("witness"))?
            .args
        {
            let data = match arg {
                Arg::Data { hex } => hex::decode(hex).map_err(|_| bad("witness"))?,
                Arg::Signature { prefix_hex } => {
                    let mut v = hex::decode(prefix_hex).map_err(|_| bad("signature prefix"))?;
                    v.extend([0; 65]);
                    v
                }
                _ => return Err(bad("unexpected witness argument")),
            };
            b.add_data(&data).map_err(|_| bad("sizing witness"))?;
        }
        b.add_data(&bytes(&json!(script.script_hex))?)
            .map_err(|_| bad("sizing program"))?;
    } else {
        b.add_data(&[0; 65]).map_err(|_| bad("sizing signature"))?;
    }
    estimate.inputs[selected].signature_script = b.drain();
    let calc = MassCalculator::new(
        MAINNET_PARAMS.mass_per_tx_byte,
        MAINNET_PARAMS.mass_per_script_pub_key_byte,
        MAINNET_PARAMS.storage_mass_parameter,
    );
    let non = calc.calc_non_contextual_masses(&estimate);
    let ctx = calc
        .calc_contextual_masses(&PopulatedTransaction::new(&estimate, entries.to_vec()))
        .ok_or_else(|| bad("storage mass unavailable"))?;
    let cf = MAINNET_PARAMS.block_mass_cofactors();
    let mass = non
        .compute_mass
        .max((non.transient_mass as f64 * cf.transient).ceil() as u64)
        .max((ctx.storage_mass as f64 * cf.storage).ceil() as u64);
    let fee = entries.iter().map(|e| e.amount).sum::<u64>()
        - tx.outputs.iter().map(|o| o.value).sum::<u64>();
    let limits = MAINNET_PARAMS.block_mass_limits;
    check(
        non.compute_mass <= limits.compute
            && non.transient_mass <= limits.transient
            && ctx.storage_mass <= limits.storage
            && fee >= mass.saturating_mul(100)
            && fee <= mass.saturating_mul(1500).min(100_000_000),
        &format!(
            "network mass/fee outside independently sized bounds (compute {}, transient {}, storage {}, fee {}, effective {})",
            non.compute_mass, non.transient_mass, ctx.storage_mass, fee, mass
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    const SECRET: &str = "private:0000000000000000000000000000000000000000000000000000000000000001";
    fn request(name: &str) -> PsktRequest {
        request_network(name, false)
    }
    fn request_network(name: &str, mainnet: bool) -> PsktRequest {
        let d: Value = serde_json::from_str(if mainnet {
            include_str!("fixtures/kforge-mainnet-unsigned.json")
        } else { include_str!("fixtures/kforge-tn10-unsigned.json") }).unwrap();
        let row = &d["trades"][name];
        let response = &row["response"];
        let t = &row["token"];
        let buy = name.ends_with("buy");
        let pool = name.starts_with("pool");
        let buy_budget = if buy {
            Some(if pool {num(&row["body"]["kas"]).unwrap()} else {num(&response["cost"]).unwrap()})
        } else {None};
        let existing = response["mergedInto"]["amount"].as_u64().or_else(|| {
            let wallet=row.get("wallet").unwrap_or(&d["wallet"]).as_str()?;
            d["wallets"][wallet]["holdings"].as_array()?.iter()
                .find(|h|h["tokenCovId"]==t["tokenCovId"])?["amount"].as_u64()
        }).unwrap_or(0);
        serde_json::from_value(json!({"sender":row.get("wallet").unwrap_or(&d["wallet"]),"profile":if mainnet{"kforge-mainnet-swap-v1"}else{"kforge-tn10-swap-v1"},"tokenId":t["tokenCovId"],"lpCovenantId":if pool{&t["pool"]["poolCovId"]}else{&t["rungCovId"]},"ticker":t["ticker"],"side":if buy{"buy"}else{"sell"},"tradeSummary":{"network":if mainnet{"mainnet"}else{"testnet-10"},"market":t,"amount":if pool{if buy{&row["body"]["kas"]}else{&row["body"]["tokens"]}}else{&row["body"]["qty"]},"maximumDebit":"4500000000000000","minimumOut":"1","buyBudgetSompi":buy_budget,"existingAmount":existing,"leftover":response["leftover"].as_u64().unwrap_or(0)},"txJsonString":response["txJson"],"signInputs":[{"index":response["inputIndex"],"sighashType":1,"expectedSighash":response["sighash"]}],"scripts":[]})).unwrap()
    }
    fn synthetic(name: &str) -> PsktRequest {
        synthetic_network(name, false)
    }
    fn synthetic_network(name: &str, mainnet: bool) -> PsktRequest {
        let mut r = request_network(name, mainnet);
        let received = num(&crate::prepare_pskt(&r).unwrap().trade_summary.unwrap()["verified"]["tokens"]).unwrap();
        let old = Address::try_from(r.sender.as_str()).unwrap();
        let mut sender = crate::derive_address(SECRET).unwrap();
        sender.prefix = if mainnet {Prefix::Mainnet} else {Prefix::Testnet};
        let p = pay_to_address_script(&sender);
        let wallet = format!("{:04x}{}", p.version(), hex::encode(p.script()));
        let mut tx: Value = serde_json::from_str(&r.tx_json_string).unwrap();
        tx.as_object_mut().unwrap().remove("id");
        let terms = r.trade_summary.as_ref().unwrap();
        let buy = name.ends_with("buy");
        let pool = name.starts_with("pool");
        let replace = |o: &mut Value, input: bool| {
            let old_p = pay_to_address_script(&old);
            let old_wallet = format!("{:04x}{}", old_p.version(), hex::encode(old_p.script()));
            let obj = if input { &mut o["utxo"] } else { o };
            if obj["scriptPublicKey"] == old_wallet {
                obj["scriptPublicKey"] = json!(wallet);
                obj["address"] = Value::Null;
                return;
            }
            if (if input {
                &obj["covenantId"]
            } else {
                &obj["covenant"]["covenantId"]
            }) == &json!(r.token_id)
            {
                let amount = if input {
                    if buy {
                        num(&terms["existingAmount"]).unwrap()
                    } else {
                        num(&terms["leftover"]).unwrap()
                            + if pool {
                                num(&terms["amount"]).unwrap()
                            } else {
                                num(&terms["amount"]).unwrap() * LOT
                            }
                    }
                } else {
                    if buy {
                        num(&terms["existingAmount"]).unwrap() + received
                    } else {
                        num(&terms["leftover"]).unwrap()
                    }
                };
                if let Ok(mut n) = verify_note_input(
                    &json!({"utxo":{"scriptPublicKey":obj["scriptPublicKey"]}}),
                    amount,
                    old.payload.to_vec(),
                    0,
                ) {
                    n.owner = sender.payload.to_vec();
                    obj["scriptPublicKey"] = json!(packed(&n.program().unwrap()));
                    obj["address"] = Value::Null;
                }
            }
        };
        for i in tx["inputs"].as_array_mut().unwrap() {
            replace(i, true);
        }
        for o in tx["outputs"].as_array_mut().unwrap() {
            replace(o, false);
        }
        r.sender = sender.to_string();
        r.tx_json_string = tx.to_string();
        r.sign_inputs[0].expected_sighash = Some(crate::pskt::kforge_fixture_sighash(&r).unwrap());
        r
    }
    #[test]
    fn kas_buy_budget_is_enforced_and_bound_into_review() {
        for mainnet in [false, true] {
            for name in ["curve-buy", "pool-buy"] {
                let r = request_network(name, mainnet);
                let budget = num(&r.trade_summary.as_ref().unwrap()["buyBudgetSompi"]).unwrap();
                for value in [Value::Null, json!(0), json!(budget - 1)] {
                    let mut x = r.clone();
                    x.trade_summary.as_mut().unwrap()["buyBudgetSompi"] = value;
                    assert!(crate::prepare_pskt(&x).is_err());
                }
                let mut x = r.clone();
                x.trade_summary.as_mut().unwrap()["buyBudgetSompi"] = json!(budget + 1);
                if name == "pool-buy" {
                    assert!(crate::prepare_pskt(&x).is_err());
                } else {
                    let original = crate::prepare_pskt(&r).unwrap();
                    let increased = crate::prepare_pskt(&x).unwrap();
                    assert_ne!(original.review_hash, increased.review_hash);
                    assert_eq!(increased.trade_summary.unwrap()["verified"]["unspentBudgetSompi"], "1");
                    let t = &r.trade_summary.as_ref().unwrap()["market"];
                    let next = num(&t["base"]).unwrap() + num(&t["slope"]).unwrap() * (num(&t["sold"]).unwrap() + 1);
                    x.trade_summary.as_mut().unwrap()["buyBudgetSompi"] = json!(budget + next);
                    assert!(crate::prepare_pskt(&x).is_err(), "must select the extra affordable lot");
                }
            }
        }
    }
    #[test]
    fn mainnet_profiles_match_real_unsigned_plans_and_execute_locally() {
        for name in ["curve-buy", "curve-sell", "pool-buy", "pool-sell", "curve-p2sh-buy"] {
            let r = request_network(name, true);
            let review = crate::prepare_pskt(&r).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(review.trade_summary.unwrap()["verified"]["network"], "mainnet");
            // Synthetic, local-only key/outpoints: never sign public wallets.
            let r = synthetic_network(name, true);
            let review = crate::prepare_pskt(&r).unwrap();
            let signed = crate::sign_pskt(SECRET, &r, &review.review_hash)
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(signed.transaction_id, review.transaction_id);
            assert!(signed.wrpc_json.is_some());
        }
    }
    #[test]
    fn mainnet_rejects_cross_network_profiles_parameters_and_fee_programs() {
        for mainnet in [true, false] {
            let r = request_network("curve-buy", mainnet);
            for field in ["network", "base", "slope", "creator", "profile", "sender"] {
                let mut x = r.clone();
                match field {
                    "network" => x.trade_summary.as_mut().unwrap()["network"] = json!(if mainnet{"testnet-10"}else{"mainnet"}),
                    "base" | "slope" => x.trade_summary.as_mut().unwrap()["market"][field] = json!(1),
                    "creator" => x.trade_summary.as_mut().unwrap()["market"][field] = json!(format!("000020{}ac", "44".repeat(32))),
                    "profile" => x.profile = Some(if mainnet{"kforge-tn10-swap-v1"}else{"kforge-mainnet-swap-v1"}.into()),
                    "sender" => {let mut a = Address::try_from(x.sender.as_str()).unwrap();a.prefix=if mainnet{Prefix::Testnet}else{Prefix::Mainnet};x.sender=a.to_string();},
                    _ => unreachable!(),
                }
                assert!(crate::prepare_pskt(&x).is_err(), "{mainnet} {field}");
            }
        }
    }
    #[test]
    fn public_unsigned_plans_match_all_four_independent_profiles() {
        for name in ["curve-buy", "curve-sell", "pool-buy", "pool-sell"] {
            let r = request(name);
            let review = crate::prepare_pskt(&r).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert!(review.trade_summary.unwrap()["verified"].is_object());
        }
    }
    #[test]
    fn full_curve_and_pool_witnesses_execute_in_local_vm() {
        for name in ["curve-buy", "curve-sell", "pool-buy", "pool-sell"] {
            let r = synthetic(name);
            let review = crate::prepare_pskt(&r).unwrap();
            let signed = crate::sign_pskt(SECRET, &r, &review.review_hash)
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(signed.transaction_id, review.transaction_id);
            assert!(signed.wrpc_json.is_some());
        }
    }
    #[test]
    fn rejects_changed_ownership_network_bounds_fees_and_programs() {
        for name in ["curve-buy", "curve-sell", "pool-buy", "pool-sell"] {
            let r = request(name);
            for field in ["creator", "tokenCovId"] {
                let mut a = r.clone();
                a.trade_summary.as_mut().unwrap()["market"][field] = json!("44".repeat(32));
                assert!(crate::prepare_pskt(&a).is_err());
            }
            let mut a = r.clone();
            a.sender = a.sender.replace("kaspatest:", "kaspa:");
            assert!(crate::prepare_pskt(&a).is_err());
            let mut a = r.clone();
            a.sign_inputs[0].sighash_type = 129;
            assert!(crate::prepare_pskt(&a).is_err());
            let mut a = r.clone();
            a.sign_inputs[0].expected_sighash = Some("00".repeat(32));
            assert!(crate::prepare_pskt(&a).is_err());
            let mut a = r.clone();
            a.trade_summary.as_mut().unwrap()["minimumOut"] = json!("9999999999999");
            assert!(crate::prepare_pskt(&a).is_err());
            let mut a = r.clone();
            let mut tx: Value = serde_json::from_str(&a.tx_json_string).unwrap();
            tx["outputs"][0]["value"] = json!("1");
            a.tx_json_string = tx.to_string();
            assert!(crate::prepare_pskt(&a).is_err());
            let mut a = r.clone();
            let mut tx: Value = serde_json::from_str(&a.tx_json_string).unwrap();
            tx["inputs"][0]["signatureScript"] = json!("00");
            a.tx_json_string = tx.to_string();
            assert!(crate::prepare_pskt(&a).is_err());
        }
    }
}
