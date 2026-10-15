use crate::hidden_kas::*;
use serde_json::{json, Value};
const SEED:&str="mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
fn fixture() -> Request {
    let signers = derive(SEED, 0, 0, 2).unwrap();
    let rows=signers.iter().enumerate().map(|(i,a)|json!({"address":a.address,
        "outpoint":{"transactionId":format!("{:02x}",i+1).repeat(32),"index":0},
        "utxoEntry":{"amount":"1000000000","blockDaaScore":"5000","isCoinbase":false,
        "scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(kaspa_txscript::pay_to_address_script(&kaspa_addresses::Address::try_from(a.address.as_str()).unwrap()).script())}}})).collect::<Vec<_>>();
    Request {
        descriptor: DESCRIPTOR.into(),
        recipient: crate::derive_address(SEED).unwrap().to_string(),
        amount_sompi: 100000000,
        fee_rate: 100.0,
        signers,
        change: derive(SEED, 1, 0, 1).unwrap().remove(0),
        utxos_json: json!(rows).to_string(),
    }
}
#[test]
fn hidden_kas_rpc_default_script_version_can_be_spent_and_recovered() {
    let mut r = fixture();
    let mut rows: Value = serde_json::from_str(&r.utxos_json).unwrap();
    for row in rows.as_array_mut().unwrap() {
        row["utxoEntry"]["scriptPublicKey"].as_object_mut().unwrap().remove("version");
    }
    r.utxos_json = rows.to_string();
    let review = prepare(&r).unwrap();
    let mut signed = sign(SEED, &r, review["reviewHash"].as_str().unwrap()).unwrap();
    signed["request"] = serde_json::to_value(&r).unwrap();
    verify_saved(SEED, &signed).unwrap();
    for version in [json!(1), json!(-1), json!(null), json!("0")] {
        let mut invalid = rows.clone();
        invalid[0]["utxoEntry"]["scriptPublicKey"]["version"] = version;
        let mut altered = r.clone();
        altered.utxos_json = invalid.to_string();
        assert!(prepare(&altered).is_err());
    }
    let mut invalid = rows.clone();
    invalid[0]["utxoEntry"]["scriptPublicKey"]["scriptPublicKey"] = json!("00");
    r.utxos_json = invalid.to_string();
    assert!(prepare(&r).is_err());
}
#[test]
fn hidden_kas_single_seed_p2sh_spend_executes_consensus_vm() {
    let r = fixture();
    let p = prepare(&r).unwrap();
    assert_eq!(p["inputCount"], 2);
    assert!(p["changeSompi"].as_u64().unwrap() > 0);
    let signed = sign(SEED, &r, p["reviewHash"].as_str().unwrap()).unwrap();
    let mut journal = signed.clone();
    journal["request"] = serde_json::to_value(&r).unwrap();
    verify_saved(SEED, &journal).unwrap();
    let mut altered = journal.clone();
    let mut submitted: Value =
        serde_json::from_str(journal["submitJson"].as_str().unwrap()).unwrap();
    submitted["transaction"]["outputs"][0]["amount"] = json!(999999999);
    altered["submitJson"] = json!(submitted.to_string());
    assert!(verify_saved(SEED, &altered).is_err());
    let mut broken = journal.clone();
    let mut tx: Value = serde_json::from_str(journal["submitJson"].as_str().unwrap()).unwrap();
    let mut witness = hex::decode(
        tx["transaction"]["inputs"][0]["signatureScript"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    witness[2] ^= 1;
    tx["transaction"]["inputs"][0]["signatureScript"] = json!(hex::encode(&witness));
    broken["submitJson"] = json!(tx.to_string());
    assert!(verify_saved(SEED, &broken).is_err());
    witness[65] = 0x02;
    tx["transaction"]["inputs"][0]["signatureScript"] = json!(hex::encode(&witness));
    broken["submitJson"] = json!(tx.to_string());
    assert!(verify_saved(SEED, &broken).is_err());
    assert!(verify_saved(
        "mnemonic:legal winner thank year wave sausage worth useful legal winner thank yellow",
        &journal
    )
    .is_err());
    let tx: Value = serde_json::from_str(signed["submitJson"].as_str().unwrap()).unwrap();
    assert_eq!(tx["transaction"]["outputs"].as_array().unwrap().len(), 2);
    for input in tx["transaction"]["inputs"].as_array().unwrap() {
        assert_eq!(input["sigOpCount"], 1);
    }
    assert_eq!(
        r.signers[0].address,
        "kaspa:prguvhxfnrx520s8u7jm77hvw7wqy394urnymj32cp783ek0y8ftxxtznwft6"
    );
    assert_eq!(
        r.signers[0].key_hash,
        "9c5a3934cde81b25bd11bbaa13b9d91d22cfd41b70e93c19d4a6acb34e5eb3e1"
    );
    assert_eq!(
        hex::encode(redeem(&r.signers[0].key_hash).unwrap()),
        "76aa209c5a3934cde81b25bd11bbaa13b9d91d22cfd41b70e93c19d4a6acb34e5eb3e188ac"
    );
}
#[test]
fn hidden_kas_domains_and_public_material_stay_separate() {
    let r = fixture();
    assert!(r.signers.iter().all(|a| a.address.starts_with("kaspa:p")));
    assert_ne!(r.signers[0].address, r.signers[1].address);
    assert_ne!(r.signers[0].address, r.change.address);
    assert_ne!(
        r.signers[0].address,
        crate::derive_address(SEED).unwrap().to_string()
    );
    assert!(derive(
        "private:0101010101010101010101010101010101010101010101010101010101010101",
        0,
        0,
        1
    )
    .is_err());
    assert!(derive(&format!("hd-path:m/44'/111111'/0'/0/0:{SEED}"), 0, 0, 1).is_err());
    for (branch, start, count) in [
        (2, 0, 1),
        (0, 0, 0),
        (0, 9999, 2),
        (0, 0, 101),
        (0, u32::MAX, 1),
    ] {
        assert!(derive(SEED, branch, start, count).is_err());
    }
    let json = serde_json::to_string(&r.signers).unwrap();
    assert!(!json.contains("publicKey"));
    assert!(!json.contains("mnemonic"));
}
#[test]
fn hidden_kas_review_binds_every_payment_and_derivation_field() {
    let r = fixture();
    let p = prepare(&r).unwrap();
    let hash = p["reviewHash"].as_str().unwrap();
    let mut variants = vec![];
    let mut t = r.clone();
    t.amount_sompi += 1;
    variants.push(t);
    let mut t = r.clone();
    t.fee_rate += 1.0;
    variants.push(t);
    let mut t = r.clone();
    t.change = derive(SEED, 1, 1, 1).unwrap().remove(0);
    variants.push(t);
    let mut t = r.clone();
    t.signers[0].index = 1;
    variants.push(t);
    let mut t = r.clone();
    t.recipient = t.recipient.replace("kaspa:", "kaspatest:");
    variants.push(t);
    let mut t = r.clone();
    t.descriptor = "attacker".into();
    variants.push(t);
    for t in variants {
        assert!(sign(SEED, &t, hash).is_err());
    }
    assert!(sign(
        "mnemonic:legal winner thank year wave sausage worth useful legal winner thank yellow",
        &r,
        hash
    )
    .is_err());
}
#[test]
fn hidden_kas_untrusted_inputs_and_no_partial_drain_fail_closed() {
    let r = fixture();
    let rows: Value = serde_json::from_str(&r.utxos_json).unwrap();
    for field in ["amount", "blockDaaScore", "isCoinbase", "scriptPublicKey"] {
        let mut t = r.clone();
        let mut data = rows.clone();
        data[0]["utxoEntry"].as_object_mut().unwrap().remove(field);
        t.utxos_json = data.to_string();
        assert!(prepare(&t).is_err(), "{field}");
    }
    for (field, value) in [
        ("isCoinbase", json!(true)),
        ("covenantId", json!("01".repeat(32))),
        ("amount", json!("-1")),
    ] {
        let mut t = r.clone();
        let mut data = rows.clone();
        data[0]["utxoEntry"][field] = value;
        t.utxos_json = data.to_string();
        assert!(prepare(&t).is_err());
    }
    let mut t = r.clone();
    t.utxos_json = json!([rows[0], rows[0]]).to_string();
    assert!(prepare(&t).is_err());
    let mut t = r.clone();
    t.utxos_json = json!([rows[0]]).to_string();
    assert!(prepare(&t).is_err());
    let mut t = r.clone();
    t.amount_sompi = 2000000000;
    assert!(prepare(&t).is_err());
    let mut t = r.clone();
    t.change = t.signers[0].clone();
    assert!(prepare(&t).is_err());
    let mut t = r.clone();
    t.recipient = t.signers[0].address.clone();
    assert!(prepare(&t).is_err());
    for fee in [f64::NAN, f64::INFINITY, 0.0, 1001.0] {
        let mut t = r.clone();
        t.fee_rate = fee;
        assert!(prepare(&t).is_err());
    }
}
