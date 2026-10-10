//! KaspaCom PSKT adapter. Discovery/API responses never choose wallet signing
//! indexes, change recipients or seller payouts. Kaspire marketplace is separate.
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    mass::{ContextualMasses, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{SignableTransaction, Transaction, TransactionInput, TransactionOutput, UtxoEntry},
};
use kaspa_txscript::{
    extract_script_pub_key_address,
    opcodes::codes::{OpCheckSig, OpEndIf, OpFalse, OpIf},
    pay_to_address_script, pay_to_script_hash_script, pay_to_script_hash_signature_script,
    script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// Official KaspaCom commission script, observed in each documented API family.
const COMMISSION_SCRIPT: &str =
    "00002103f9216815010c3bf302ad5cb47da3a1caacb3ca7c546555ecc3b996a65ff0ad01ab";
// Pinned public KaspaCom API-account commission destination, independently
// counterchecked against delegated order quotes. This is not an API credential.
const EXCHANGE_SCRIPT: &str =
    "000020079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449ac";
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub action: String,
    pub kind: String,
    pub sender: String,
    pub seller: String,
    #[serde(default)]
    pub ticker: String,
    #[serde(default)]
    pub token_id: String,
    #[serde(default)]
    pub asset_id: String,
    #[serde(default)]
    pub amount: String,
    #[serde(default)]
    pub listing_transaction_id: String,
    #[serde(default)]
    pub listing_utxos_json: String,
    #[serde(default)]
    pub wallet_utxos_json: String,
    #[serde(default)]
    pub seller_pskt: String,
    #[serde(default)]
    pub price_sompi: u64,
    #[serde(default)]
    pub fee_sompi: u64,
    #[serde(default)]
    pub exchange_fee_sompi: u64,
    #[serde(default)]
    pub royalty_sompi: u64,
    #[serde(default)]
    pub royalty_address: String,
    #[serde(default = "rate")]
    pub fee_rate: f64,
}
fn rate() -> f64 {
    1.0
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidRequest(s.into())
}
fn platform_fee(price: u64, delegated: bool) -> u64 {
    // Live delegated quotes split the 2.5% fee into two 1.25% shares,
    // each with a 0.5 KAS minimum. KaspaCom rounds each share to 0.001 KAS.
    // Compute in integer sompi, never using API-selected rates or floats.
    let divisor = if delegated { 80u128 } else { 40u128 };
    let step = divisor * 100_000;
    (((u128::from(price) + step / 2) / step) * 100_000).max(50_000_000) as u64
}
fn address(s: &str) -> Result<Address> {
    let a = Address::try_from(s).map_err(|_| CoreError::InvalidAddress)?;
    if a.prefix != Prefix::Mainnet || a.version != Version::PubKey {
        return Err(invalid("KaspaCom requires a mainnet Schnorr wallet"));
    }
    Ok(a)
}
pub fn descriptor(r: &Request) -> Result<Value> {
    let seller = address(&r.seller)?;
    let (namespace, payload) = match r.kind.as_str() {
        "krc721" => {
            return crate::nft_market::descriptor(&r.seller, &r.ticker, &r.token_id);
        }
        "krc20" => {
            if r.ticker.is_empty()
                || r.ticker.len() > 10
                || !r.ticker.bytes().all(|c| c.is_ascii_alphanumeric())
            {
                return Err(invalid("Invalid KRC20 ticker"));
            }
            (
                "kasplex",
                format!(
                    "{{\"p\":\"krc-20\",\"op\":\"send\",\"tick\":\"{}\"}}",
                    r.ticker.to_lowercase()
                ),
            )
        }
        "kns" => {
            if r.asset_id.len() != 66
                || !r.asset_id.ends_with("i0")
                || !r.asset_id[..64].bytes().all(|c| c.is_ascii_hexdigit())
            {
                return Err(invalid("Invalid KNS inscription ID"));
            }
            (
                "kns",
                format!(
                    "{{\"op\":\"send\",\"id\":\"{}\"}}",
                    r.asset_id.to_lowercase()
                ),
            )
        }
        _ => return Err(invalid("Unsupported KaspaCom asset")),
    };
    let mut b = ScriptBuilder::new();
    b.add_data(&seller.payload)
        .and_then(|b| b.add_op(OpCheckSig))
        .and_then(|b| b.add_op(OpFalse))
        .and_then(|b| b.add_op(OpIf))
        .and_then(|b| b.add_data(namespace.as_bytes()))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_data(payload.as_bytes()))
        .and_then(|b| b.add_op(OpEndIf))
        .map_err(|e| invalid(&e.to_string()))?;
    let redeem = b.drain();
    let spk = pay_to_script_hash_script(&redeem);
    let listing = extract_script_pub_key_address(&spk, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?;
    Ok(
        json!({"listingAddress":listing.to_string(),"redeemScript":hex::encode(redeem),"payload":payload}),
    )
}
fn packed(s: &kaspa_consensus_core::tx::ScriptPublicKey) -> String {
    format!("{:04x}{}", s.version(), hex::encode(s.script()))
}
fn tx_json(tx: &Transaction, entries: &[UtxoEntry]) -> Value {
    json!({"version":0,"inputs":tx.inputs.iter().zip(entries).map(|(i,e)|json!({"transactionId":i.previous_outpoint.transaction_id.to_string(),"index":i.previous_outpoint.index,"sequence":i.sequence.to_string(),"sigOpCount":1,"signatureScript":hex::encode(&i.signature_script),"utxo":{"address":extract_script_pub_key_address(&e.script_public_key,Prefix::Mainnet).ok().map(|a|a.to_string()),"amount":e.amount.to_string(),"scriptPublicKey":packed(&e.script_public_key),"blockDaaScore":e.block_daa_score.to_string(),"isCoinbase":e.is_coinbase}})).collect::<Vec<_>>(),"outputs":tx.outputs.iter().map(|o|json!({"value":o.value.to_string(),"scriptPublicKey":packed(&o.script_public_key)})).collect::<Vec<_>>(),"lockTime":"0","subnetworkId":"0000000000000000000000000000000000000000","gas":"0","payload":"","storageMass":tx.storage_mass().to_string()})
}
// Repair transport-only metadata for already signed build-159 purchases. This
// never changes any consensus field or signature, and does not sign/broadcast.
pub fn normalize_transport_pskt(raw: &str, buyer: &str) -> Result<String> {
    let buyer = address(buyer)?;
    let mut tx: Value = serde_json::from_str(raw).map_err(|_| invalid("Invalid buyer PSKT"))?;
    let inputs = tx["inputs"]
        .as_array_mut()
        .ok_or_else(|| invalid("Missing inputs"))?;
    if !(2..=81).contains(&inputs.len()) {
        return Err(invalid("Unexpected buyer input count"));
    }
    for (index, input) in inputs.iter_mut().enumerate() {
        let utxo = input["utxo"]
            .as_object_mut()
            .ok_or_else(|| invalid("Missing input UTXO"))?;
        let raw = utxo
            .get("scriptPublicKey")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("Missing input script"))?;
        let bytes = hex::decode(raw).map_err(|_| invalid("Invalid input script"))?;
        if bytes.len() < 3 {
            return Err(invalid("Invalid packed input script"));
        }
        let script = kaspa_consensus_core::tx::ScriptPublicKey::new(
            u16::from_be_bytes([bytes[0], bytes[1]]),
            bytes[2..].to_vec().into(),
        );
        let derived = extract_script_pub_key_address(&script, Prefix::Mainnet)
            .map_err(|_| invalid("Unsupported input script"))?;
        if (index == 0 && derived.version != Version::ScriptHash) || (index > 0 && derived != buyer)
        {
            return Err(invalid(
                "Input address differs from authenticated buyer/listing",
            ));
        }
        let address = derived.to_string();
        if utxo
            .get("address")
            .is_some_and(|v| !v.is_null() && v.as_str() != Some(address.as_str()))
        {
            return Err(invalid("Input address metadata does not match its script"));
        }
        utxo.insert("address".into(), json!(address));
    }
    Ok(tx.to_string())
}
fn raw(r: &Request) -> Result<Value> {
    let sender = address(&r.sender)?;
    let seller = address(&r.seller)?;
    let d = descriptor(r)?;
    if !["offer", "buy", "cancel"].contains(&r.action.as_str())
        || !r.fee_rate.is_finite()
        || !(1.0..=1000.0).contains(&r.fee_rate)
    {
        return Err(invalid("Invalid KaspaCom action or fee rate"));
    }
    if r.action != "buy" && sender != seller {
        return Err(invalid("Only the seller can list or cancel"));
    }
    if r.action == "buy" && sender == seller {
        return Err(invalid("Use Cancel listing to recover your own asset"));
    }
    let listing = Address::try_from(d["listingAddress"].as_str().unwrap())
        .map_err(|_| CoreError::InvalidAddress)?;
    let cells = crate::transaction::parse_utxos(&r.listing_utxos_json, &listing)?;
    let cell = cells
        .iter()
        .find(|c| {
            c.outpoint.transaction_id.to_string() == r.listing_transaction_id
                && c.outpoint.index == 0
        })
        .ok_or_else(|| {
            invalid("Listing UTXO is not spendable; it may already be bought or cancelled")
        })?;
    let redeem =
        hex::decode(d["redeemScript"].as_str().unwrap()).map_err(|_| CoreError::Serialization)?;
    let mut tx = Transaction::new(
        0,
        vec![TransactionInput::new(cell.outpoint.clone(), vec![], 0, 1)],
        vec![],
        0,
        SUBNETWORK_ID_NATIVE,
        0,
        vec![],
    );
    let mut entries = vec![cell.entry.clone()];
    if r.action != "cancel" {
        if r.price_sompi == 0 || r.price_sompi % 1_000_000 != 0 {
            return Err(invalid("KaspaCom price must have at most two decimals"));
        }
        tx.outputs.push(TransactionOutput::new(
            r.price_sompi
                .checked_add(cell.entry.amount)
                .ok_or_else(|| invalid("Price overflow"))?,
            pay_to_address_script(&seller),
        ));
    }
    if r.action == "offer" {
        return Ok(json!({"transaction":tx_json(&tx,&entries),"descriptor":d,"networkFeeSompi":0}));
    }
    if r.action == "buy" {
        // Backend appends fee outputs and masks its stored seller signature.
        // Only input 0 may be external. Every funding input belongs to the buyer.
        let order: Value =
            serde_json::from_str(&r.seller_pskt).map_err(|_| invalid("Invalid seller PSKT"))?;
        let inputs = order["inputs"]
            .as_array()
            .ok_or_else(|| invalid("Seller PSKT inputs missing"))?;
        let outputs = order["outputs"]
            .as_array()
            .ok_or_else(|| invalid("Seller PSKT outputs missing"))?;
        if inputs.len() != 1
            || inputs[0]["transactionId"] != r.listing_transaction_id
            || inputs[0]["index"].as_u64() != Some(0)
            || outputs.is_empty()
            || outputs.len() > 4
        {
            return Err(invalid("Unexpected seller PSKT shape"));
        }
        if order["version"].as_u64() != Some(0)
            || order["subnetworkId"].as_str() != Some("0000000000000000000000000000000000000000")
            || order["lockTime"].as_str() != Some("0")
            || order["gas"].as_str() != Some("0")
            || order["payload"].as_str() != Some("")
            || inputs[0]["sequence"].as_str() != Some("0")
            || inputs[0]["sigOpCount"].as_u64() != Some(1)
            || inputs[0]
                .pointer("/utxo/covenantId")
                .is_some_and(|v| !v.is_null())
        {
            return Err(invalid("Unsupported seller transaction semantics"));
        }
        let expected = tx_json(&tx, &entries);
        if outputs[0] != expected["outputs"][0]
            && !(outputs[0]["value"] == expected["outputs"][0]["value"]
                && outputs[0]["scriptPublicKey"] == expected["outputs"][0]["scriptPublicKey"]
                && outputs[0].get("covenant").is_none_or(Value::is_null))
        {
            return Err(invalid("Seller payout differs from displayed price"));
        }
        let spk = inputs[0]
            .pointer("/utxo/scriptPublicKey")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("Seller UTXO script missing"))?;
        if spk != packed(&cell.entry.script_public_key)
            || inputs[0].pointer("/utxo/amount").and_then(Value::as_str)
                != Some(&cell.entry.amount.to_string())
        {
            return Err(invalid("Seller UTXO differs from live node proof"));
        }
        if r.fee_sompi != platform_fee(r.price_sompi, r.exchange_fee_sompi != 0) {
            return Err(invalid("Unexpected KaspaCom platform fee"));
        }
        if r.exchange_fee_sompi != 0 && r.exchange_fee_sompi != r.fee_sompi {
            return Err(invalid("Unexpected KaspaCom external exchange commission"));
        }
        if r.kind != "krc721" && r.royalty_sompi != 0 {
            return Err(invalid("Royalties are allowed only for NFTs"));
        }
        if r.royalty_sompi > r.price_sompi {
            return Err(invalid("NFT royalty exceeds sale price"));
        }
        let sig = hex::decode(
            inputs[0]["signatureScript"]
                .as_str()
                .ok_or_else(|| invalid("Seller signature missing"))?,
        )
        .map_err(|_| invalid("Invalid seller signature"))?;
        // The authenticated API masks the seller signature. Never treat arbitrary
        // external scripts as a KaspaCom placeholder, or broadcast this PSKT.
        if sig.len() < 66 || sig.len() > 1024 || !sig.iter().all(|b| *b == 255) {
            return Err(invalid("Expected the KaspaCom masked seller signature"));
        }
        tx.inputs[0].signature_script = sig;
        let mut funds = crate::transaction::parse_utxos(&r.wallet_utxos_json, &sender)?;
        funds.sort_by(|a, b| {
            b.entry
                .amount
                .cmp(&a.entry.amount)
                .then(
                    a.outpoint
                        .transaction_id
                        .to_string()
                        .cmp(&b.outpoint.transaction_id.to_string()),
                )
                .then(a.outpoint.index.cmp(&b.outpoint.index))
        });
        for f in funds.into_iter().take(80) {
            if f.outpoint == cell.outpoint {
                return Err(invalid("Duplicate seller/funding input"));
            }
            tx.inputs
                .push(TransactionInput::new(f.outpoint, vec![0; 66], 0, 1));
            entries.push(f.entry);
        }
        tx.outputs.push(TransactionOutput::new(
            10_000,
            pay_to_address_script(&sender),
        ));
        let fee_spk = kaspa_consensus_core::tx::ScriptPublicKey::new(
            0,
            hex::decode(&COMMISSION_SCRIPT[4..]).unwrap().into(),
        );
        tx.outputs
            .push(TransactionOutput::new(r.fee_sompi, fee_spk));
        if r.exchange_fee_sompi > 0 {
            tx.outputs.push(TransactionOutput::new(
                r.exchange_fee_sompi,
                kaspa_consensus_core::tx::ScriptPublicKey::new(
                    0,
                    hex::decode(&EXCHANGE_SCRIPT[4..]).unwrap().into(),
                ),
            ));
        }
        if r.royalty_sompi > 0 {
            tx.outputs.push(TransactionOutput::new(
                r.royalty_sompi,
                pay_to_address_script(&address(&r.royalty_address)?),
            ));
        }
        if outputs.len() != tx.outputs.len() - 1 {
            return Err(invalid("Missing or unexpected commission/royalty output"));
        }
        for (external, ours) in outputs.iter().skip(1).zip(tx.outputs.iter().skip(2)) {
            if external["value"].as_str() != Some(&ours.value.to_string())
                || external["scriptPublicKey"].as_str() != Some(&packed(&ours.script_public_key))
                || external.get("covenant").is_some_and(|v| !v.is_null())
            {
                return Err(invalid(
                    "KaspaCom fee recipient or amount does not match the review",
                ));
            }
        }
    } else {
        tx.inputs[0].signature_script = pay_to_script_hash_signature_script(redeem, vec![0; 66])
            .map_err(|_| invalid("Invalid listing script"))?;
        tx.outputs.push(TransactionOutput::new(
            10_000,
            pay_to_address_script(&seller),
        ));
    }
    let total = entries
        .iter()
        .try_fold(0u64, |a, e| a.checked_add(e.amount))
        .ok_or_else(|| invalid("Input overflow"))?;
    let change = if r.action == "buy" { 1 } else { 0 };
    let fixed = tx
        .outputs
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != change)
        .try_fold(0u64, |a, (_, o)| a.checked_add(o.value))
        .ok_or_else(|| invalid("Output overflow"))?;
    let calc = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut fee = 0u64;
    let mut mass_final = None;
    for _ in 0..16 {
        let value = total
            .checked_sub(fixed)
            .and_then(|v| v.checked_sub(fee))
            .ok_or(CoreError::InsufficientFunds)?;
        if value < 10_000 {
            return Err(CoreError::InsufficientFunds);
        }
        tx.outputs[change].value = value;
        let p = SignableTransaction::with_entries(tx.clone(), entries.clone());
        let c = calc
            .calc_contextual_masses(&p.as_verifiable())
            .ok_or_else(|| invalid("Storage mass unavailable"))?;
        let mass = Mass::new(
            calc.calc_non_contextual_masses(&tx),
            ContextualMasses::new(c.storage_mass),
        )
        .normalized_max(&MAINNET_PARAMS.block_mass_cofactors());
        let required = (r.fee_rate * mass as f64).ceil() as u64;
        if fee >= required {
            mass_final = Some(mass);
            break;
        }
        fee = required;
    }
    tx.set_storage_mass(mass_final.ok_or_else(|| invalid("Network fee did not converge"))?);
    if r.action == "buy" {
        for i in tx.inputs.iter_mut().skip(1) {
            i.signature_script.clear();
        }
    } else {
        tx.inputs[0].signature_script.clear();
    }
    Ok(json!({"transaction":tx_json(&tx,&entries),"descriptor":d,"networkFeeSompi":fee}))
}
fn request(r: &Request, built: &Value) -> Value {
    let buy = r.action == "buy";
    let hash = if r.action == "offer" { 132 } else { 1 };
    let indexes = if buy {
        (1..built["transaction"]["inputs"].as_array().unwrap().len())
            .map(|i| json!({"index":i,"sighashType":1}))
            .collect::<Vec<_>>()
    } else {
        vec![json!({"index":0,"sighashType":hash})]
    };
    let scripts = if buy {
        vec![]
    } else {
        vec![
            json!({"inputIndex":0,"scriptHex":built["descriptor"]["redeemScript"],"signType":hash,"signatureScript":{"mode":"wrap-signature"}}),
        ]
    };
    json!({"sender":r.sender,"profile":"kaspacom-market-v1","side":r.action,"tradeSummary":r,"txJsonString":built["transaction"].to_string(),"signInputs":indexes,"scripts":scripts})
}
pub fn prepare(r: &Request) -> Result<Value> {
    if r.action == "describe" {
        return descriptor(r);
    }
    let b = raw(r)?;
    let req = request(r, &b);
    let p: crate::pskt::PsktRequest =
        serde_json::from_value(req.clone()).map_err(|_| CoreError::Serialization)?;
    let review = crate::pskt::prepare_pskt(&p)?;
    Ok(
        json!({"request":req,"review":review,"descriptor":b["descriptor"],"networkFeeSompi":b["networkFeeSompi"]}),
    )
}
pub fn validate(r: &crate::pskt::PsktRequest) -> Result<()> {
    let args: Request = serde_json::from_value(
        r.trade_summary
            .clone()
            .ok_or_else(|| invalid("Missing KaspaCom terms"))?,
    )
    .map_err(|_| invalid("Invalid KaspaCom terms"))?;
    let normalized: crate::pskt::PsktRequest = serde_json::from_value(request(&args, &raw(&args)?))
        .map_err(|_| CoreError::Serialization)?;
    let expected = serde_json::to_value(normalized).map_err(|_| CoreError::Serialization)?;
    let mut actual = serde_json::to_value(r).map_err(|_| CoreError::Serialization)?;
    // JSONObject normalizes integral Doubles (100.0 -> 100) on Android.
    // Canonicalize only this typed floating-point field, not transaction JSON,
    // payout amounts, scripts, signing indexes or other reviewed terms.
    if actual["tradeSummary"].get("feeRate").is_some() {
        actual["tradeSummary"]["feeRate"] = json!(args.fee_rate);
    }
    // Compare the signing request's fields, not just the payment amount.
    if actual != expected {
        return Err(invalid(
            "KaspaCom transaction or signing policy differs from reviewed terms",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const SECRET: &str = "mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    #[test]
    fn live_public_and_delegated_fee_rounding() {
        for (price, public, delegated) in [
            (2_100_000_000, 52_500_000, 50_000_000),
            (4_200_000_000, 105_000_000, 52_500_000),
            (22_875_000_000, 571_900_000, 285_900_000),
        ] {
            assert_eq!(platform_fee(price, false), public);
            assert_eq!(platform_fee(price, true), delegated);
            for kind in ["krc20", "krc721", "kns"] {
                for delegated_quote in [false, true] {
                    let mut offer = fixture(kind);
                    offer.price_sompi = price;
                    let mut r = buyer(offer);
                    r.fee_sompi = if delegated_quote { delegated } else { public };
                    r.exchange_fee_sompi = if delegated_quote { delegated } else { 0 };
                    let a = Address::try_from(r.sender.as_str()).unwrap();
                    r.wallet_utxos_json = cells(&a, &"22".repeat(32), 100_000_000_000);
                    let mut seller: Value = serde_json::from_str(&r.seller_pskt).unwrap();
                    seller["outputs"][1]["value"] = json!(r.fee_sompi.to_string());
                    if delegated_quote {
                        seller["outputs"].as_array_mut().unwrap().push(json!({
                            "value":r.exchange_fee_sompi.to_string(),"scriptPublicKey":EXCHANGE_SCRIPT
                        }));
                    }
                    r.seller_pskt = seller.to_string();
                    assert!(prepare(&r).is_ok(), "{kind} {price} {delegated_quote}");
                    r.fee_sompi += 1;
                    assert!(prepare(&r).is_err());
                }
            }
        }
    }
    fn cells(a: &Address, id: &str, amount: u64) -> String {
        json!([{"address":a.to_string(),"outpoint":{"transactionId":id,"index":0},"utxoEntry":{"amount":amount.to_string(),"blockDaaScore":"100","isCoinbase":false,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(a).script())}}}]).to_string()
    }
    fn fixture(kind: &str) -> Request {
        let seller = crate::derive_address(SECRET).unwrap().to_string();
        let mut r: Request = serde_json::from_value(json!({"action":"offer","kind":kind,"sender":seller,"seller":seller,"ticker":"NACHO","tokenId":"82","assetId":format!("{}i0","aa".repeat(32)),"amount":"22200000000","listingTransactionId":"11".repeat(32),"priceSompi":500000000})).unwrap();
        let d = descriptor(&r).unwrap();
        let a = Address::try_from(d["listingAddress"].as_str().unwrap()).unwrap();
        r.listing_utxos_json = cells(&a, &r.listing_transaction_id, 105000000);
        r
    }
    fn buyer(mut r: Request) -> Request {
        let b = prepare(&r).unwrap();
        let mut tx: Value =
            serde_json::from_str(b["request"]["txJsonString"].as_str().unwrap()).unwrap();
        tx["inputs"][0]["signatureScript"] = json!("ff".repeat(200));
        tx["outputs"]
            .as_array_mut()
            .unwrap()
            .push(json!({"value":"50000000","scriptPublicKey":COMMISSION_SCRIPT}));
        r.seller_pskt = tx.to_string();
        r.action = "buy".into();
        r.fee_sompi = 50000000;
        let a = crate::derive_address(&format!("private:{}", "02".repeat(32))).unwrap();
        r.sender = a.to_string();
        r.wallet_utxos_json = cells(&a, &"22".repeat(32), 2000000000);
        r
    }
    #[test]
    fn all_protocols_offer_buy_cancel_and_policy_binding() {
        for kind in ["krc20", "krc721", "kns"] {
            let r = fixture(kind);
            let built = prepare(&r).unwrap();
            let req: crate::pskt::PsktRequest =
                serde_json::from_value(built["request"].clone()).unwrap();
            let review = crate::prepare_pskt(&req).unwrap();
            let signed = crate::sign_pskt(SECRET, &req, &review.review_hash).unwrap();
            assert!(signed.submit_json.is_none());
            assert_eq!(review.outputs[0].amount_sompi, 605000000);
            let buy = buyer(r.clone());
            let b = prepare(&buy).unwrap();
            let req: crate::pskt::PsktRequest =
                serde_json::from_value(b["request"].clone()).unwrap();
            assert_eq!(req.sign_inputs[0].index, 1);
            assert!(req.scripts.is_empty());
            let review = crate::prepare_pskt(&req).unwrap();
            let signed = crate::sign_pskt(
                &format!("private:{}", "02".repeat(32)),
                &req,
                &review.review_hash,
            )
            .unwrap();
            assert_eq!(signed.signed_input_indexes, vec![1]);
            for change in ["fee", "price", "signature", "account", "utxo"] {
                let mut bad = buy.clone();
                match change {
                    "fee" => bad.fee_sompi += 1,
                    "price" => bad.price_sompi += 1000000,
                    "signature" => {
                        let mut t: Value = serde_json::from_str(&bad.seller_pskt).unwrap();
                        t["inputs"][0]["signatureScript"] = json!("00".repeat(200));
                        bad.seller_pskt = t.to_string();
                    }
                    "account" => bad.sender = bad.seller.clone(),
                    _ => bad.wallet_utxos_json = "[]".into(),
                };
                assert!(prepare(&bad).is_err(), "{kind} {change}");
            }
            let mut bad = req.clone();
            bad.ticker = Some("MISLEADING".into());
            assert!(crate::prepare_pskt(&bad).is_err());
            let mut bad = req.clone();
            bad.sign_inputs[0].index = 0;
            assert!(crate::prepare_pskt(&bad).is_err());
            let mut cancel = r;
            cancel.action = "cancel".into();
            let b = prepare(&cancel).unwrap();
            let req = serde_json::from_value(b["request"].clone()).unwrap();
            let review = crate::prepare_pskt(&req).unwrap();
            assert_eq!(review.outputs.len(), 1);
            assert!(crate::sign_pskt(SECRET, &req, &review.review_hash)
                .unwrap()
                .submit_json
                .is_some());
        }
    }
    #[test]
    fn delegated_purchase_binds_both_commissions_and_rejects_redirection() {
        for kind in ["krc20", "krc721", "kns"] {
            let mut r = buyer(fixture(kind));
            r.exchange_fee_sompi = r.fee_sompi;
            let mut seller: Value = serde_json::from_str(&r.seller_pskt).unwrap();
            seller["outputs"].as_array_mut().unwrap().push(
                json!({"value":r.exchange_fee_sompi.to_string(),"scriptPublicKey":EXCHANGE_SCRIPT}),
            );
            r.seller_pskt = seller.to_string();
            let built = prepare(&r).unwrap();
            let tx = &built["request"]["txJsonString"];
            let tx: Value = serde_json::from_str(tx.as_str().unwrap()).unwrap();
            assert_eq!(tx["outputs"].as_array().unwrap().len(), 4);
            assert_eq!(tx["outputs"][2]["scriptPublicKey"], COMMISSION_SCRIPT);
            assert_eq!(tx["outputs"][3]["scriptPublicKey"], EXCHANGE_SCRIPT);
            let req = serde_json::from_value(built["request"].clone()).unwrap();
            let review = crate::prepare_pskt(&req).unwrap();
            assert!(crate::sign_pskt(
                &format!("private:{}", "02".repeat(32)),
                &req,
                &review.review_hash
            )
            .is_ok());
            let mut bad = r.clone();
            bad.exchange_fee_sompi += 1;
            assert!(prepare(&bad).is_err());
            let mut bad = r.clone();
            seller["outputs"][2]["scriptPublicKey"] = json!(COMMISSION_SCRIPT);
            bad.seller_pskt = seller.to_string();
            assert!(prepare(&bad).is_err());
        }
    }
    #[test]
    fn transport_recovery_only_adds_script_derived_addresses() {
        for kind in ["krc20", "krc721", "kns"] {
            let r = buyer(fixture(kind));
            let b = prepare(&r).unwrap();
            let req = serde_json::from_value(b["request"].clone()).unwrap();
            let review = crate::prepare_pskt(&req).unwrap();
            let signed = crate::sign_pskt(
                &format!("private:{}", "02".repeat(32)),
                &req,
                &review.review_hash,
            )
            .unwrap();
            let original: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
            let mut legacy = original.clone();
            for i in legacy["inputs"].as_array_mut().unwrap() {
                i["utxo"].as_object_mut().unwrap().remove("address");
            }
            let recovered: Value = serde_json::from_str(
                &normalize_transport_pskt(&legacy.to_string(), &r.sender).unwrap(),
            )
            .unwrap();
            assert_eq!(recovered, original, "only address metadata may change");
            assert_eq!(recovered["id"], original["id"]);
            assert_eq!(
                recovered["inputs"][0]["utxo"]["address"],
                b["descriptor"]["listingAddress"]
            );
            assert_eq!(recovered["inputs"][1]["utxo"]["address"], r.sender);
            assert!(normalize_transport_pskt(&legacy.to_string(), &r.seller).is_err());
            let mut bad = original.clone();
            bad["inputs"][0]["utxo"]["address"] = json!(r.seller);
            assert!(normalize_transport_pskt(&bad.to_string(), &r.sender).is_err());
        }
    }
    #[test]
    fn mobile_json_integral_fee_rate_preserves_reviewed_terms() {
        for kind in ["krc20", "krc721", "kns"] {
            let mut r = buyer(fixture(kind));
            r.fee_rate = 100.0;
            let built = prepare(&r).unwrap();
            let mut transported = built["request"].clone();
            // Android JSONObject emits an integral Double as 100, not 100.0.
            transported["tradeSummary"]["feeRate"] = json!(100);
            let req = serde_json::from_value(transported.clone()).unwrap();
            let review = crate::prepare_pskt(&req).unwrap();
            assert!(crate::sign_pskt(
                &format!("private:{}", "02".repeat(32)),
                &req,
                &review.review_hash
            )
            .is_ok());
            for field in ["priceSompi", "feeSompi"] {
                let mut altered = transported.clone();
                altered["tradeSummary"][field] = json!(1);
                let req = serde_json::from_value(altered).unwrap();
                assert!(crate::prepare_pskt(&req).is_err());
            }
            let mut altered = transported.clone();
            altered["signInputs"][0]["index"] = json!(0);
            let req = serde_json::from_value(altered).unwrap();
            assert!(crate::prepare_pskt(&req).is_err());
            transported["tradeSummary"]["feeRate"] = json!(101);
            let req = serde_json::from_value(transported).unwrap();
            assert!(crate::prepare_pskt(&req).is_err());
        }
    }
    #[test]
    fn kns_descriptor_matches_live_official_listing() {
        let r:Request=serde_json::from_value(json!({"action":"describe","kind":"kns","sender":"kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs","seller":"kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs","assetId":"ccd09583adb22408b102124406df3884dbdda1dbead36832c127b889b254c516i0"})).unwrap();
        assert_eq!(
            descriptor(&r).unwrap()["listingAddress"],
            "kaspa:pq7ukjz4hpq3nwvuyt2vnue9d5xwucnnat37wlv825dec2hz0yjc6d72rdalw"
        );
    }
    #[test]
    fn wallet_authentication_rejects_message_and_account_substitution() {
        let a = crate::derive_address(SECRET).unwrap().to_string();
        let message = "Kaspire KaspaCom Marketplace\nNonce: example-only";
        let sig = crate::sign_personal_message(SECRET, &a, message).unwrap();
        assert!(crate::verify_kaspacom_login(&a, message, &sig).is_ok());
        assert!(crate::verify_kaspacom_login(&a, "another purpose", &sig).is_err());
        let other = crate::derive_address(&format!("private:{}", "02".repeat(32)))
            .unwrap()
            .to_string();
        assert!(crate::verify_kaspacom_login(&other, message, &sig).is_err());
    }
    #[test]
    fn partner_list_commit_amount_and_reveal_are_consistent() {
        for kind in ["krc20", "kns"] {
            let r = fixture(kind);
            let op = crate::InscriptionRequest {
                kind: format!("{kind}-list"),
                sender: r.seller.clone(),
                recipient: r.seller.clone(),
                ticker: r.ticker.clone(),
                amount: r.amount.clone(),
                token_id: r.token_id.clone(),
                asset_id: r.asset_id.clone(),
            };
            let p = crate::prepare_inscription(&op).unwrap();
            assert_eq!(p.commit_amount_sompi, 200000000);
            let a = Address::try_from(p.commit_address.as_str()).unwrap();
            let req = crate::RevealRequest {
                operation: op,
                commit_transaction_id: "33".repeat(32),
                commit_utxos_json: cells(&a, &"33".repeat(32), p.commit_amount_sompi),
                fee_rate: 1.0,
            };
            let review = crate::prepare_reveal(&req).unwrap();
            assert!(crate::sign_reveal(SECRET, &req, &review.review_hash).is_ok());
        }
    }
}
