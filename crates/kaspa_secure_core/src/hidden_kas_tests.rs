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
        send_all: false,
        fee_rate: 100.0,
        signers,
        change: derive(SEED, 1, 0, 1).unwrap().remove(0),
        utxos_json: json!(rows).to_string(),
    }
}

#[test]
fn kip22_max_deducts_native_fee_and_spends_all_inputs_without_change() {
    for rate in [1.0, 2.5, 100.0, 1000.0] {
        let mut r = fixture();
        r.send_all = true;
        r.amount_sompi = 0;
        r.fee_rate = rate;
        let review = prepare(SEED, &r).unwrap();
        assert_eq!(review["sendAll"], true);
        assert_eq!(review["changeSompi"], 0);
        assert_eq!(review["inputCount"], 2);
        let amount = review["amountSompi"].as_u64().unwrap();
        let fee = review["feeSompi"].as_u64().unwrap();
        assert_eq!(amount + fee, 2000000000);
        assert!(fee >= (review["mass"].as_u64().unwrap() as f64 * rate).ceil() as u64);
        let mut saved = sign(SEED, &r, review["reviewHash"].as_str().unwrap()).unwrap();
        saved["request"] = serde_json::to_value(&r).unwrap();
        verify_saved(SEED, &saved).unwrap();
        let tx: Value = serde_json::from_str(saved["submitJson"].as_str().unwrap()).unwrap();
        assert_eq!(tx["transaction"]["outputs"].as_array().unwrap().len(), 1);
        assert_eq!(
            tx["transaction"]["outputs"][0]["amount"].as_u64().unwrap(),
            amount
        );
    }
}

#[test]
fn kip22_max_is_bound_to_review_and_cannot_hide_an_amount_or_excess_fee() {
    let mut r = fixture();
    let ordinary = prepare(SEED, &r).unwrap();
    let serialized = serde_json::to_value(&r).unwrap();
    assert!(serialized.get("sendAll").is_none());
    assert!(
        !serde_json::from_value::<Request>(serialized)
            .unwrap()
            .send_all
    );
    r.send_all = true;
    assert!(
        prepare(SEED, &r).is_err(),
        "Max uses canonical amount=0 only"
    );
    r.amount_sompi = 0;
    let max = prepare(SEED, &r).unwrap();
    assert!(sign(SEED, &r, ordinary["reviewHash"].as_str().unwrap()).is_err());
    let mut changed = r.clone();
    changed.send_all = false;
    changed.amount_sompi = max["amountSompi"].as_u64().unwrap();
    assert!(sign(SEED, &changed, max["reviewHash"].as_str().unwrap()).is_err());
    let mut rows: Value = serde_json::from_str(&r.utxos_json).unwrap();
    rows[0]["utxoEntry"]["amount"] = json!("6000");
    rows[1]["utxoEntry"]["amount"] = json!("6000");
    r.utxos_json = rows.to_string();
    r.fee_rate = 1000.0;
    assert!(
        prepare(SEED, &r).is_err(),
        "insufficient fee/dust must not sign"
    );
}
#[test]
fn browser_decimal_requests_preserve_native_review_hashes_and_recovery() {
    for max in [false, true] {
        let mut r = fixture();
        r.send_all = max;
        if max {
            r.amount_sompi = 0;
        }
        let review = prepare(SEED, &r).unwrap();
        let mut request = serde_json::to_value(&r).unwrap();
        request["amountSompi"] = json!(r.amount_sompi.to_string());
        let restored: Request = serde_json::from_value(request.clone()).unwrap();
        assert_eq!(prepare(SEED, &restored).unwrap(), review);
        let mut saved = sign(SEED, &restored, review["reviewHash"].as_str().unwrap()).unwrap();
        saved["request"] = request;
        verify_saved(SEED, &saved).unwrap();
    }
    for value in [
        json!("+1"),
        json!("01"),
        json!("1e8"),
        json!("18446744073709551616"),
        json!(1.5),
        json!(-1),
        json!(null),
    ] {
        let mut request = serde_json::to_value(fixture()).unwrap();
        request["amountSompi"] = value;
        assert!(serde_json::from_value::<Request>(request).is_err());
    }
}
#[test]
fn hidden_kas_rpc_default_script_version_can_be_spent_and_recovered() {
    let mut r = fixture();
    let mut rows: Value = serde_json::from_str(&r.utxos_json).unwrap();
    for row in rows.as_array_mut().unwrap() {
        row["utxoEntry"]["scriptPublicKey"]
            .as_object_mut()
            .unwrap()
            .remove("version");
    }
    r.utxos_json = rows.to_string();
    let review = prepare(SEED, &r).unwrap();
    let mut signed = sign(SEED, &r, review["reviewHash"].as_str().unwrap()).unwrap();
    signed["request"] = serde_json::to_value(&r).unwrap();
    verify_saved(SEED, &signed).unwrap();
    for version in [json!(1), json!(-1), json!(null), json!("0")] {
        let mut invalid = rows.clone();
        invalid[0]["utxoEntry"]["scriptPublicKey"]["version"] = version;
        let mut altered = r.clone();
        altered.utxos_json = invalid.to_string();
        assert!(prepare(SEED, &altered).is_err());
    }
    let mut invalid = rows.clone();
    invalid[0]["utxoEntry"]["scriptPublicKey"]["scriptPublicKey"] = json!("00");
    r.utxos_json = invalid.to_string();
    assert!(prepare(SEED, &r).is_err());
}
#[test]
fn hidden_kas_single_seed_p2sh_spend_executes_consensus_vm() {
    let r = fixture();
    let p = prepare(SEED, &r).unwrap();
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
        "kaspa:pq02dzckvs0g6hhl9s9c484fv0wsd93sltwct9symfad4yw062w5y4v4mtlxa"
    );
}

#[test]
fn kip22_matches_bip32_reference_path_and_minimal_script() {
    use kaspa_addresses::Prefix;
    use kaspa_bip32::{DerivationPath, ExtendedPrivateKey, Language, Mnemonic, PrivateKey};
    use kaspa_txscript::{extract_script_pub_key_address, pay_to_script_hash_script};
    use std::str::FromStr;
    // Public, never-funded vector. Deliberately use the dependency's plain
    // BIP32 implementation, not the production path/key/script constructors.
    let mnemonic = Mnemonic::new(
        SEED.strip_prefix("mnemonic:").unwrap().to_string(),
        Language::English,
    )
    .unwrap();
    let seed = mnemonic.to_seed("");
    let root = ExtendedPrivateKey::<kaspa_bip32::SecretKey>::new(seed.as_bytes()).unwrap();
    for branch in 0..=1 {
        for index in [0, 1, 19, 20, 9999] {
            let path =
                DerivationPath::from_str(&format!("m/22'/111111'/0'/{branch}/{index}")).unwrap();
            let derived = root.clone().derive_path(&path).unwrap();
            let mut raw_key = derived.private_key().to_bytes();
            let mut pair =
                secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, &raw_key).unwrap();
            let public = pair.x_only_public_key().0.serialize();
            pair.non_secure_erase();
            raw_key.fill(0);
            let mut expected_script = vec![0x20];
            expected_script.extend_from_slice(&public);
            expected_script.push(0xac);
            assert_eq!(redeem(&public).unwrap(), expected_script);
            let expected = extract_script_pub_key_address(
                &pay_to_script_hash_script(&expected_script),
                Prefix::Mainnet,
            )
            .unwrap();
            let actual = derive(SEED, branch, index, 1).unwrap().remove(0);
            assert_eq!(actual.address, expected.to_string());
            let encoded = serde_json::to_string(&actual).unwrap();
            assert!(
                !encoded.contains(&hex::encode(public)),
                "pre-spend key disclosure"
            );
            assert!(
                !encoded.contains(&hex::encode(expected_script)),
                "pre-spend script disclosure"
            );
        }
    }
    assert_eq!(PATH_PREFIX, "m/22'/111111'/0'");
}

#[test]
fn kip22_rejects_old_descriptor_and_checks_ownership_before_review() {
    let r = fixture();
    let mut old = r.clone();
    old.descriptor = "kaspire-hidden-kas-v1".into();
    assert!(prepare(SEED, &old).is_err());
    let wrong_seed =
        "mnemonic:legal winner thank year wave sausage worth useful legal winner thank yellow";
    assert!(prepare(wrong_seed, &r).is_err());
    let mut altered = r.clone();
    altered.signers[0].key_hash = "00".repeat(32);
    assert!(prepare(SEED, &altered).is_err());
    let p = prepare(SEED, &r).unwrap();
    assert_eq!(p["kipRevision"], KIP_REVISION);
    assert_eq!(p["derivationPrefix"], PATH_PREFIX);
    // Neither public key nor redeem script may leave Rust before signing.
    let signed = sign(SEED, &r, p["reviewHash"].as_str().unwrap()).unwrap();
    let tx: Value = serde_json::from_str(signed["submitJson"].as_str().unwrap()).unwrap();
    for input in tx["transaction"]["inputs"].as_array().unwrap() {
        let witness = hex::decode(input["signatureScript"].as_str().unwrap()).unwrap();
        assert_eq!(witness.len(), 101);
        assert_eq!(witness[0], 65);
        assert_eq!(witness[65], 1); // SIGHASH_ALL
        assert_eq!(witness[66], 34);
        assert_eq!(witness[67], 32);
        assert_eq!(witness[100], 0xac);
        let review = serde_json::to_string(&p).unwrap();
        assert!(!review.contains(&hex::encode(&witness[68..100])));
    }
    // Passphrase is part of the HD root; not a second incompatible path.
    let with_passphrase = format!(
        "mnemonic-passphrase:{}:{}",
        hex::encode("TREZOR"),
        SEED.strip_prefix("mnemonic:").unwrap()
    );
    assert_ne!(derive(&with_passphrase, 0, 0, 1).unwrap(), r.signers[..1]);
    let signed = sign(&with_passphrase, &r, p["reviewHash"].as_str().unwrap());
    assert!(
        signed.is_err(),
        "a different BIP39 root cannot sign the reviewed account"
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
    let p = prepare(SEED, &r).unwrap();
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
        assert!(prepare(SEED, &t).is_err(), "{field}");
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
        assert!(prepare(SEED, &t).is_err());
    }
    let mut t = r.clone();
    t.utxos_json = json!([rows[0], rows[0]]).to_string();
    assert!(prepare(SEED, &t).is_err());
    let mut t = r.clone();
    t.utxos_json = json!([rows[0]]).to_string();
    assert!(prepare(SEED, &t).is_err());
    let mut t = r.clone();
    t.amount_sompi = 2000000000;
    assert!(prepare(SEED, &t).is_err());
    let mut t = r.clone();
    t.change = t.signers[0].clone();
    assert!(prepare(SEED, &t).is_err());
    let mut t = r.clone();
    t.recipient = t.signers[0].address.clone();
    assert!(prepare(SEED, &t).is_err());
    for fee in [f64::NAN, f64::INFINITY, 0.0, 1001.0] {
        let mut t = r.clone();
        t.fee_rate = fee;
        assert!(prepare(SEED, &t).is_err());
    }
}
