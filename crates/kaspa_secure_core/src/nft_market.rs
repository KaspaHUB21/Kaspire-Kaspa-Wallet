//! Native, deterministic KRC721 list/send PSKT construction. The directory is
//! discovery only: never trust it to choose scripts, outputs or signing indexes.
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SigHashType,
    },
    mass::{ContextualMasses, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ScriptPublicKey, SignableTransaction, Transaction, TransactionInput, TransactionOutput,
        UtxoEntry,
    },
};
use kaspa_txscript::{
    extract_script_pub_key_address,
    opcodes::codes::{OpCheckSig, OpEndIf, OpFalse, OpIf},
    pay_to_address_script, pay_to_script_hash_script, pay_to_script_hash_signature_script,
    script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub action: String,
    pub sender: String,
    pub seller: String,
    pub ticker: String,
    pub token_id: String,
    #[serde(default)]
    pub listing_transaction_id: String,
    #[serde(default)]
    pub listing_utxos_json: String,
    #[serde(default)]
    pub wallet_utxos_json: String,
    #[serde(default)]
    pub price_sompi: u64,
    #[serde(default)]
    pub fee_address: String,
    #[serde(default)]
    pub seller_pskt: String,
    #[serde(default = "default_fee_rate")]
    pub fee_rate: f64,
}
fn default_fee_rate() -> f64 {
    1.0
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidRequest(s.into())
}
fn address(s: &str) -> Result<Address> {
    let a = Address::try_from(s).map_err(|_| CoreError::InvalidAddress)?;
    if a.prefix != Prefix::Mainnet || a.version != Version::PubKey {
        return Err(invalid("NFT marketplace requires a mainnet Schnorr wallet"));
    }
    Ok(a)
}
pub fn descriptor(seller: &str, ticker: &str, token_id: &str) -> Result<Value> {
    let a = address(seller)?;
    if ticker.is_empty() || ticker.len() > 10 || !ticker.bytes().all(|c| c.is_ascii_alphanumeric())
    {
        return Err(invalid("invalid KRC721 ticker"));
    }
    let id = token_id
        .parse::<u64>()
        .map_err(|_| invalid("invalid NFT token ID"))?;
    if id.to_string() != token_id {
        return Err(invalid("NFT token ID must be canonical"));
    }
    let payload = format!(
        "{{\"p\":\"krc-721\",\"op\":\"send\",\"tick\":\"{}\",\"tokenId\":\"{}\"}}",
        ticker.to_lowercase(),
        id
    );
    let mut b = ScriptBuilder::new();
    b.add_data(&a.payload)
        .and_then(|b| b.add_op(OpCheckSig))
        .and_then(|b| b.add_op(OpFalse))
        .and_then(|b| b.add_op(OpIf))
        .and_then(|b| b.add_data(b"kspr"))
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
fn packed(s: &ScriptPublicKey) -> String {
    format!("{:04x}{}", s.version(), hex::encode(s.script()))
}
fn tx_json(tx: &Transaction, entries: &[UtxoEntry]) -> Value {
    json!({"version":0,"inputs":tx.inputs.iter().zip(entries).map(|(i,e)| json!({"transactionId":i.previous_outpoint.transaction_id.to_string(),"index":i.previous_outpoint.index,"sequence":"0","sigOpCount":1,"signatureScript":hex::encode(&i.signature_script),"utxo":{"amount":e.amount.to_string(),"scriptPublicKey":packed(&e.script_public_key),"blockDaaScore":e.block_daa_score.to_string(),"isCoinbase":false}})).collect::<Vec<_>>(),"outputs":tx.outputs.iter().map(|o|json!({"value":o.value.to_string(),"scriptPublicKey":packed(&o.script_public_key)})).collect::<Vec<_>>(),"lockTime":"0","subnetworkId":"0000000000000000000000000000000000000000","gas":"0","payload":"","storageMass":tx.storage_mass().to_string()})
}
fn raw(r: &Request) -> Result<Value> {
    let sender = address(&r.sender)?;
    let seller = address(&r.seller)?;
    let d = descriptor(&r.seller, &r.ticker, &r.token_id)?;
    let listing = Address::try_from(d["listingAddress"].as_str().unwrap())
        .map_err(|_| CoreError::InvalidAddress)?;
    let redeem =
        hex::decode(d["redeemScript"].as_str().unwrap()).map_err(|_| CoreError::Serialization)?;
    let cells = crate::transaction::parse_utxos(&r.listing_utxos_json, &listing)?;
    let cell = cells
        .iter()
        .find(|c| {
            c.outpoint.transaction_id.to_string() == r.listing_transaction_id
                && c.outpoint.index == 0
        })
        .ok_or_else(|| {
            invalid("NFT listing output is not currently spendable; refresh and retry")
        })?;
    if !(1.0..=1000.0).contains(&r.fee_rate) || !r.fee_rate.is_finite() {
        return Err(invalid("invalid NFT market fee rate"));
    }
    if !["offer", "buy", "cancel", "verify-offer"].contains(&r.action.as_str()) {
        return Err(invalid("unknown NFT market action"));
    }
    if !["buy", "verify-offer"].contains(&r.action.as_str()) && sender != seller {
        return Err(invalid("only the NFT seller can list or cancel"));
    }
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
    let fee = r
        .price_sompi
        .checked_mul(21)
        .and_then(|v| v.checked_add(999))
        .ok_or_else(|| invalid("NFT price overflow"))?
        / 1000;
    if r.action != "cancel" {
        if r.price_sompi < 10_000 || fee < 10_000 {
            return Err(invalid(
                "NFT price too small for the marketplace fee output (minimum 0.00476191 KAS)",
            ));
        }
        address(&r.fee_address)?;
        tx.outputs.push(TransactionOutput::new(
            r.price_sompi
                .checked_sub(fee)
                .and_then(|v| v.checked_add(cell.entry.amount))
                .ok_or_else(|| invalid("price overflow"))?,
            pay_to_address_script(&seller),
        ));
    }
    if r.action == "offer" {
        return Ok(
            json!({"transaction":tx_json(&tx,&entries),"descriptor":d,"feeSompi":fee,"networkFeeSompi":null}),
        );
    }
    if r.action == "buy" || r.action == "verify-offer" {
        let order: Value =
            serde_json::from_str(&r.seller_pskt).map_err(|_| invalid("invalid seller PSKT"))?;
        let sig_hex = order
            .pointer("/inputs/0/signatureScript")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("seller signature missing"))?;
        let sig =
            hex::decode(sig_hex).map_err(|_| invalid("seller signature is not hexadecimal"))?;
        if sig.len() < 66 || sig[0] != 65 || sig[65] != 132 {
            return Err(invalid("NFT seller must sign SINGLE|ANYONECANPAY"));
        }
        let expected = pay_to_script_hash_signature_script(redeem.clone(), sig[..66].to_vec())
            .map_err(|_| invalid("invalid NFT seller signature wrapper"))?;
        if expected != sig {
            return Err(invalid(
                "NFT seller signature has an unexpected redeem script",
            ));
        }
        // Verify against OUR deterministic outpoint, UTXO and seller payout.
        let populated = SignableTransaction::with_entries(tx.clone(), entries.clone());
        let hash = calc_schnorr_signature_hash(
            &populated.as_verifiable(),
            0,
            SigHashType::from_u8(132).unwrap(),
            &SigHashReusedValuesUnsync::new(),
        );
        secp256k1::Secp256k1::verification_only()
            .verify_schnorr(
                &secp256k1::schnorr::Signature::from_slice(&sig[1..65])
                    .map_err(|_| invalid("invalid seller signature"))?,
                &secp256k1::Message::from_digest_slice(&hash.as_bytes())
                    .map_err(|_| invalid("invalid seller sighash"))?,
                &secp256k1::XOnlyPublicKey::from_slice(&seller.payload)
                    .map_err(|_| invalid("invalid seller public key"))?,
            )
            .map_err(|_| invalid("seller signature does not authorize this NFT and price"))?;
        tx.inputs[0].signature_script = sig;
        if r.action == "verify-offer" {
            return Ok(json!({"transaction":tx_json(&tx,&entries),"descriptor":d,"feeSompi":fee}));
        }
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
        let mut total = 0u64;
        for fund in funds.into_iter().take(80) {
            total = total
                .checked_add(fund.entry.amount)
                .ok_or_else(|| invalid("wallet amount overflow"))?;
            tx.inputs
                .push(TransactionInput::new(fund.outpoint, vec![0; 66], 0, 1));
            entries.push(fund.entry);
        }
        tx.outputs.push(TransactionOutput::new(
            10_000,
            pay_to_address_script(&sender),
        ));
        tx.outputs.push(TransactionOutput::new(
            fee,
            pay_to_address_script(&address(&r.fee_address)?),
        ));
    } else {
        tx.inputs[0].signature_script = pay_to_script_hash_signature_script(redeem, vec![0; 66])
            .map_err(|_| invalid("invalid cancel redeem script"))?;
        tx.outputs.push(TransactionOutput::new(
            10_000,
            pay_to_address_script(&seller),
        ));
    }
    let total = entries
        .iter()
        .try_fold(0u64, |a, e| a.checked_add(e.amount))
        .ok_or_else(|| invalid("input overflow"))?;
    let fixed = if r.action == "buy" {
        tx.outputs[0]
            .value
            .checked_add(fee)
            .ok_or_else(|| invalid("output overflow"))?
    } else {
        0
    };
    let change_index = if r.action == "buy" { 1 } else { 0 };
    let calc = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut network_fee = 0u64;
    let mut final_mass = None;
    for _ in 0..16 {
        let change = total
            .checked_sub(fixed)
            .and_then(|v| v.checked_sub(network_fee))
            .ok_or(CoreError::InsufficientFunds)?;
        if change < 10_000 {
            return Err(CoreError::InsufficientFunds);
        }
        tx.outputs[change_index].value = change;
        let populated = SignableTransaction::with_entries(tx.clone(), entries.clone());
        let contextual = calc
            .calc_contextual_masses(&populated.as_verifiable())
            .ok_or_else(|| invalid("NFT transaction storage mass unavailable"))?;
        let mass = Mass::new(
            calc.calc_non_contextual_masses(&tx),
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&MAINNET_PARAMS.block_mass_cofactors());
        let required = (r.fee_rate * mass as f64).ceil() as u64;
        if network_fee >= required {
            final_mass = Some(mass);
            break;
        }
        network_fee = required;
    }
    tx.set_storage_mass(final_mass.ok_or_else(|| invalid("NFT network fee did not converge"))?);
    if r.action == "buy" {
        for input in tx.inputs.iter_mut().skip(1) {
            input.signature_script.clear();
        }
    } else {
        tx.inputs[0].signature_script.clear();
    }
    Ok(
        json!({"transaction":tx_json(&tx,&entries),"descriptor":d,"feeSompi":if r.action=="buy"{fee}else{0},"networkFeeSompi":network_fee}),
    )
}
pub fn prepare(r: &Request) -> Result<Value> {
    if r.action == "describe" {
        return descriptor(&r.seller, &r.ticker, &r.token_id);
    }
    let built = raw(r)?;
    if r.action == "verify-offer" {
        return Ok(built);
    }
    let is_buy = r.action == "buy";
    let tx = &built["transaction"];
    let sign_inputs = if is_buy {
        (1..tx["inputs"].as_array().unwrap().len())
            .map(|i| json!({"index":i,"sighashType":1}))
            .collect::<Vec<_>>()
    } else {
        vec![json!({"index":0,"sighashType":if r.action=="offer"{132}else{1}})]
    };
    let scripts = if is_buy {
        vec![]
    } else {
        vec![
            json!({"inputIndex":0,"scriptHex":built["descriptor"]["redeemScript"],"signType":if r.action=="offer"{132}else{1},"signatureScript":{"mode":"wrap-signature"}}),
        ]
    };
    let request = json!({"sender":r.sender,"profile":"krc721-market-v1","ticker":r.ticker,"tokenId":r.token_id,"side":r.action,"tradeSummary":r,"txJsonString":tx.to_string(),"signInputs":sign_inputs,"scripts":scripts});
    let parsed: crate::pskt::PsktRequest =
        serde_json::from_value(request.clone()).map_err(|_| CoreError::Serialization)?;
    let review = crate::pskt::prepare_pskt(&parsed)?;
    Ok(
        json!({"request":request,"review":review,"descriptor":built["descriptor"],"feeSompi":built["feeSompi"],"networkFeeSompi":built["networkFeeSompi"]}),
    )
}
pub fn validate(r: &crate::pskt::PsktRequest) -> Result<()> {
    let args: Request = serde_json::from_value(
        r.trade_summary
            .clone()
            .ok_or_else(|| invalid("NFT market terms missing"))?,
    )
    .map_err(|_| invalid("invalid NFT market terms"))?;
    if !["offer", "buy", "cancel"].contains(&args.action.as_str()) {
        return Err(invalid("read-only NFT action cannot be signed"));
    }
    let expected = raw(&args)?;
    let actual: Value =
        serde_json::from_str(&r.tx_json_string).map_err(|_| CoreError::Serialization)?;
    if actual != expected["transaction"]
        || r.sender != args.sender
        || r.ticker.as_deref() != Some(&args.ticker)
        || r.token_id.as_deref() != Some(&args.token_id)
        || r.side.as_deref() != Some(&args.action)
    {
        return Err(invalid(
            "NFT market transaction does not match the reviewed terms",
        ));
    }
    let indexes: Vec<(usize, u8)> = r
        .sign_inputs
        .iter()
        .map(|s| (s.index, s.sighash_type))
        .collect();
    let wanted: Vec<(usize, u8)> = if args.action == "buy" {
        (1..actual["inputs"].as_array().unwrap().len())
            .map(|i| (i, 1))
            .collect()
    } else {
        vec![(0, if args.action == "offer" { 132 } else { 1 })]
    };
    if indexes != wanted {
        return Err(invalid("incorrect NFT market signing indexes or sighash"));
    }
    if args.action == "buy" && !r.scripts.is_empty() {
        return Err(invalid("buyer must not replace the seller NFT signature"));
    }
    if args.action != "buy"
        && (r.scripts.len() != 1
            || r.scripts[0].input_index != 0
            || r.scripts[0].script_hex != expected["descriptor"]["redeemScript"].as_str().unwrap()
            || r.scripts[0].sign_type != Some(wanted[0].1)
            || r.scripts[0].prebuilt_signature_script.is_some()
            || !r.scripts[0].signature_offsets.is_empty()
            || r.scripts[0].signature_script.as_ref().is_none_or(|s| {
                s.mode != crate::pskt::PsktSignatureScriptMode::WrapSignature || !s.args.is_empty()
            }))
    {
        return Err(invalid("unexpected NFT listing signature template"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const SECRET:&str="mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    fn fixture() -> Request {
        let seller = crate::derive_address(SECRET).unwrap().to_string();
        let d = descriptor(&seller, "KASPUNKS", "82").unwrap();
        let a = Address::try_from(d["listingAddress"].as_str().unwrap()).unwrap();
        let cells=json!([{"address":a.to_string(),"outpoint":{"transactionId":"11".repeat(32),"index":0},"utxoEntry":{"amount":"29900000","blockDaaScore":"100","isCoinbase":false,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&a).script())}}}]).to_string();
        Request {
            action: "offer".into(),
            sender: seller.clone(),
            seller: seller.clone(),
            ticker: "KASPUNKS".into(),
            token_id: "82".into(),
            listing_transaction_id: "11".repeat(32),
            listing_utxos_json: cells,
            wallet_utxos_json: String::new(),
            price_sompi: 1_000_000_000,
            fee_address: seller,
            seller_pskt: String::new(),
            fee_rate: 1.0,
        }
    }
    fn pskt(built: &Value) -> crate::pskt::PsktRequest {
        serde_json::from_value(built["request"].clone()).unwrap()
    }
    fn funded_buyer(mut r: Request) -> Request {
        let secret = format!("private:{}", "02".repeat(32));
        let a = crate::derive_address(&secret).unwrap();
        r.sender = a.to_string();
        r.action = "buy".into();
        r.wallet_utxos_json=json!([{"address":a.to_string(),"outpoint":{"transactionId":"22".repeat(32),"index":1},"utxoEntry":{"amount":"2000000000","blockDaaScore":"100","isCoinbase":false,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&a).script())}}}]).to_string();
        r
    }
    #[test]
    fn matches_indexer_listing_script_exactly() {
        let seller = "kaspa:qzvkk6vfemsmqwku659nf37jaj9l0c2ts9rwuc0s96venfz9tzamzq9gf47f3";
        assert_eq!(descriptor(seller,"KASPUNKS","82").unwrap()["redeemScript"],"20996b6989cee1b03adcd50b34c7d2ec8bf7e14b8146ee61f02e9999a44558bbb1ac0063046b737072003c7b2270223a226b72632d373231222c226f70223a2273656e64222c227469636b223a226b617370756e6b73222c22746f6b656e4964223a223832227d68");
    }
    #[test]
    fn seller_offer_buy_and_cancel_have_correct_outputs() {
        let mut r = fixture();
        let built = prepare(&r).unwrap();
        let request = pskt(&built);
        let review = crate::prepare_pskt(&request).unwrap();
        assert_eq!(review.outputs[0].amount_sompi, 1_008_900_000);
        assert_eq!(built["feeSompi"], 21_000_000);
        let signed = crate::sign_pskt(SECRET, &request, &review.review_hash).unwrap();
        assert!(signed.submit_json.is_none());
        r.seller_pskt = signed.signed_tx_json;
        let buyer = funded_buyer(r.clone());
        let buy = prepare(&buyer).unwrap();
        let buy_request = pskt(&buy);
        let buy_review = crate::prepare_pskt(&buy_request).unwrap();
        assert_eq!(buy_review.output_count, 3);
        assert_eq!(buy_review.outputs[2].amount_sompi, 21_000_000);
        assert!(buy_review.final_fee_known);
        let purchased = crate::sign_pskt(
            &format!("private:{}", "02".repeat(32)),
            &buy_request,
            &buy_review.review_hash,
        )
        .unwrap();
        assert!(purchased.submit_json.is_some());
        let buyer_json: Value = serde_json::from_str(&purchased.signed_tx_json).unwrap();
        let seller_json: Value = serde_json::from_str(&r.seller_pskt).unwrap();
        assert_eq!(
            buyer_json["inputs"][0]["signatureScript"],
            seller_json["inputs"][0]["signatureScript"]
        );
        r.action = "cancel".into();
        let cancel = prepare(&r).unwrap();
        let cancellation = pskt(&cancel);
        let cancel_review = crate::prepare_pskt(&cancellation).unwrap();
        assert_eq!(cancel_review.output_count, 1);
        assert_eq!(
            cancel_review.outputs[0].address.as_deref(),
            Some(r.seller.as_str())
        );
        assert!(
            crate::sign_pskt(SECRET, &cancellation, &cancel_review.review_hash)
                .unwrap()
                .submit_json
                .is_some()
        );
    }
    #[test]
    fn tampering_is_rejected_before_signing() {
        let mut r = fixture();
        let built = prepare(&r).unwrap();
        let request = pskt(&built);
        let review = crate::prepare_pskt(&request).unwrap();
        let signed = crate::sign_pskt(SECRET, &request, &review.review_hash).unwrap();
        r.seller_pskt = signed.signed_tx_json;
        let buyer = funded_buyer(r);
        let buy = prepare(&buyer).unwrap();
        // Increase enough to change the signed net payout (fee rounding can
        // absorb a one-sompi gross price difference).
        let mut wrong = buyer.clone();
        wrong.price_sompi += 1000;
        assert!(prepare(&wrong).is_err());
        let mut wrong = buyer.clone();
        wrong.token_id = "83".into();
        assert!(prepare(&wrong).is_err());
        let mut wrong = buyer.clone();
        wrong.listing_transaction_id = "33".repeat(32);
        assert!(prepare(&wrong).is_err());
        let mut wrong = pskt(&buy);
        let mut tx: Value = serde_json::from_str(&wrong.tx_json_string).unwrap();
        tx["outputs"][2]["value"] = json!("1");
        wrong.tx_json_string = tx.to_string();
        assert!(crate::prepare_pskt(&wrong).is_err());
        let mut wrong = pskt(&buy);
        wrong.sign_inputs[0].index = 0;
        assert!(crate::prepare_pskt(&wrong).is_err());
        let mut wrong = pskt(&built);
        wrong.scripts[0].script_hex = "51".into();
        assert!(crate::prepare_pskt(&wrong).is_err());
        let mut wrong = buyer;
        wrong.wallet_utxos_json = "[]".into();
        assert!(prepare(&wrong).is_err());
    }
    #[test]
    fn list_reveal_pays_the_deterministic_listing_not_the_wallet() {
        let r = fixture();
        let op = crate::InscriptionRequest {
            kind: "krc721-list".into(),
            sender: r.seller.clone(),
            recipient: r.seller.clone(),
            ticker: r.ticker.clone(),
            token_id: r.token_id.clone(),
            amount: String::new(),
            asset_id: String::new(),
        };
        let p = crate::prepare_inscription(&op).unwrap();
        assert!(p.payload_json.contains("\"op\":\"list\""));
        let a = Address::try_from(p.commit_address.as_str()).unwrap();
        let txid = "44".repeat(32);
        let cells = json!([{"address":a.to_string(),"outpoint":{"transactionId":txid,"index":0},"utxoEntry":{"amount":"30000000","blockDaaScore":"100","isCoinbase":false,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&a).script())}}}]);
        let reveal = crate::RevealRequest {
            operation: op,
            commit_transaction_id: txid,
            commit_utxos_json: cells.to_string(),
            fee_rate: 1.0,
        };
        let review = crate::prepare_reveal(&reveal).unwrap();
        let signed = crate::sign_reveal(SECRET, &reveal, &review.review_hash).unwrap();
        let tx: Value = serde_json::from_str(&signed.submit_json).unwrap();
        let d = descriptor(&r.seller, &r.ticker, &r.token_id).unwrap();
        let listing = Address::try_from(d["listingAddress"].as_str().unwrap()).unwrap();
        assert_eq!(
            tx["transaction"]["outputs"][0]["scriptPublicKey"]["scriptPublicKey"],
            hex::encode(pay_to_address_script(&listing).script())
        );
    }
}
