use super::covenant_vault::*;
use crate::derive_address;
use serde_json::json;
fn fixture(kind: &str) -> (String, Request) {
    let secret = format!("private:{}", "01".repeat(32));
    let owner = derive_address(&secret).unwrap();
    let beneficiary = derive_address(&format!("private:{}", "02".repeat(32))).unwrap();
    let spk = kaspa_txscript::pay_to_address_script(&owner);
    let funding=json!([{"address":owner.to_string(),"outpoint":{"transactionId":"ab".repeat(32),"index":0},"utxoEntry":{"amount":"10000000000","blockDaaScore":"1000","isCoinbase":false,"scriptPublicKey":{"scriptPublicKey":hex::encode(spk.script())}}}]).to_string();
    (
        secret,
        Request {
            action: "create".into(),
            sender: owner.to_string(),
            terms: Terms {
                kind: kind.into(),
                owner: owner.to_string(),
                beneficiary: if kind == "timeLock" {
                    String::new()
                } else {
                    beneficiary.to_string()
                },
                limit_daa: if kind == "timeLock" { 5000 } else { 1200 },
                instance: "03".repeat(32),
                name: "Internal test".into(),
            },
            amount_sompi: 100_000_000,
            current_daa: 2000,
            fee_rate: 100.0,
            funding_utxos_json: funding,
            cell: None,
        },
    )
}
#[test]
fn portable_templates_match_official_compiler_at_integer_encoding_boundaries() {
    for kind in ["timeLock", "deadManSwitch"] {
        let (_, request) = fixture(kind);
        for limit in [1, 16, 17, 127, 128, 255, 256, 1200, 32767, 32768, 8_388_607, 8_388_608, 2_147_483_647, 2_147_483_648, 3_153_600_000, 499_999_999_999] {
            if kind == "deadManSwitch" && !(1200..=3_153_600_000).contains(&limit) { continue; }
            for seed in [1u8, 2, 127, 128, 255] {
                let mut terms = request.terms.clone(); terms.limit_daa = limit;
                terms.instance = hex::encode([seed; 32]);
                terms.owner = derive_address(&format!("private:{}", hex::encode([seed % 5 + 1; 32]))).unwrap().to_string();
                if kind == "deadManSwitch" && seed % 2 == 1 { terms.beneficiary = terms.owner.clone(); }
                let owner = kaspa_addresses::Address::try_from(terms.owner.as_str()).unwrap();
                let beneficiary = if kind == "timeLock" { vec![] } else { kaspa_addresses::Address::try_from(terms.beneficiary.as_str()).unwrap().payload.to_vec() };
                let official = compile(&terms).unwrap();
                let portable = crate::vault_templates::materialize(kind, &owner.payload, &beneficiary, limit as i64, &[seed; 32]).unwrap();
                assert_eq!(portable.bytecode, official.bytecode, "{kind} limit={limit} seed={seed}");
                assert_eq!(portable.dispatch_tags, official.dispatch_tags);
                assert_eq!(portable.template_hash(), official.template_hash());
            }
        }
    }
}
#[test]
fn official_v1_vault_genesis_and_review_binding() {
    for kind in ["timeLock", "deadManSwitch"] {
        let (secret, r) = fixture(kind);
        let p = prepare(&r).unwrap();
        assert_eq!(p["record"]["compiler"], COMPILER_PIN);
        assert_eq!(p["record"]["covenantId"].as_str().unwrap().len(), 64);
        let signed = sign(&secret, &r, p["reviewHash"].as_str().unwrap()).unwrap();
        assert_eq!(signed["transactionId"], p["transactionId"]);
        let mut changed = r.clone();
        changed.amount_sompi += 1;
        assert!(sign(&secret, &changed, p["reviewHash"].as_str().unwrap()).is_err());
    }
}
#[test]
fn instances_are_distinct_even_with_identical_wallet_and_duration() {
    for kind in ["timeLock", "deadManSwitch"] {
        let (_, r) = fixture(kind);
        let mut next = r.terms.clone();
        next.instance = "04".repeat(32);
        assert_ne!(
            descriptor(&r.terms).unwrap()["vaultAddress"],
            descriptor(&next).unwrap()["vaultAddress"]
        );
    }
}
fn live(r: &mut Request, p: &serde_json::Value) {
    r.cell = Some(Cell {
        covenant_id: p["record"]["covenantId"].as_str().unwrap().into(),
        transaction_id: p["transactionId"].as_str().unwrap().into(),
        index: 0,
        value_sompi: r.amount_sompi,
        block_daa_score: 2001,
        script_public_key: p["record"]["scriptPublicKey"].as_str().unwrap().into(),
    });
}
#[test]
fn time_lock_never_opens_early_or_pays_a_different_wallet() {
    let (secret, mut r) = fixture("timeLock");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "release".into();
    assert!(prepare(&r).is_err());
    r.current_daa = 5001;
    let review = prepare(&r).unwrap();
    sign(&secret, &r, review["reviewHash"].as_str().unwrap()).unwrap();
    r.sender = r.terms.owner.replace("kaspa:", "kaspatest:");
    assert!(prepare(&r).is_err());
}
#[test]
fn owner_pulse_preserves_covenant_id_and_full_deposit() {
    let (secret, mut r) = fixture("deadManSwitch");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "heartbeat".into();
    r.current_daa = 2100;
    let review = prepare(&r).unwrap();
    let signed = sign(&secret, &r, review["reviewHash"].as_str().unwrap()).unwrap();
    assert_eq!(signed["record"]["covenantId"], p["record"]["covenantId"]);
    assert_eq!(signed["record"]["amountSompi"], r.amount_sompi);
}
#[test]
fn beneficiary_claim_requires_mature_age_and_exact_key() {
    let (_, mut r) = fixture("deadManSwitch");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "claim".into();
    r.sender = r.terms.beneficiary.clone();
    assert!(prepare(&r).is_err());
    r.current_daa = 3202;
    let review = prepare(&r).unwrap();
    sign(
        &format!("private:{}", "02".repeat(32)),
        &r,
        review["reviewHash"].as_str().unwrap(),
    )
    .unwrap();
    assert!(sign(
        &format!("private:{}", "01".repeat(32)),
        &r,
        review["reviewHash"].as_str().unwrap()
    )
    .is_err());
}
#[test]
fn recovery_roundtrip_tampering_wrong_password_and_no_wallet_secrets() {
    let (_, r) = fixture("timeLock");
    let record = prepare(&r).unwrap()["record"].to_string();
    let password = b"Strong test passphrase 123!";
    let sealed = crate::vault_recovery::seal(password, &record).unwrap();
    assert!(!sealed.contains("Internal test"));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(
            &crate::vault_recovery::open(password, &sealed).unwrap()
        )
        .unwrap(),
        serde_json::from_str::<serde_json::Value>(&record).unwrap()
    );
    assert!(crate::vault_recovery::open(b"Wrong test passphrase", &sealed).is_err());
    let mut bad: serde_json::Value = serde_json::from_str(&sealed).unwrap();
    bad["ciphertext"] = json!("00");
    assert!(crate::vault_recovery::open(password, &bad.to_string()).is_err());
    let mut bad: serde_json::Value = serde_json::from_str(&record).unwrap();
    bad["seed"] = json!("never include");
    assert!(crate::vault_recovery::seal(password, &bad.to_string()).is_err());
}
#[test]
fn consensus_rejects_early_locktime_and_wrong_time_lock_payout_even_when_resigned() {
    let (secret, mut r) = fixture("timeLock");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "release".into();
    r.current_daa = 5001;
    assert!(rejects_mutated_transaction(&secret, &r, |tx| tx
        .lock_time =
        0));
    let wrong = derive_address(&format!("private:{}", "02".repeat(32))).unwrap();
    assert!(rejects_mutated_transaction(&secret, &r, |tx| tx.outputs
        [0]
    .script_public_key =
        kaspa_txscript::pay_to_address_script(&wrong)));
    assert!(rejects_mutated_transaction(&secret, &r, |tx| {
        tx.outputs.push(tx.outputs[0].clone());
    }));
}
#[test]
fn consensus_rejects_owner_pulse_that_reduces_balance_or_breaks_covenant_binding() {
    let (secret, mut r) = fixture("deadManSwitch");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "heartbeat".into();
    r.current_daa = 2100;
    assert!(rejects_mutated_transaction(&secret, &r, |tx| {
        tx.outputs[0].value -= 10_000;
        tx.outputs[1].value += 10_000;
    }));
    assert!(rejects_mutated_transaction(&secret, &r, |tx| tx.outputs
        [0]
    .covenant =
        None));
    assert!(rejects_mutated_transaction(&secret, &r, |tx| {
        tx.outputs[0].covenant.as_mut().unwrap().covenant_id =
            kaspa_consensus_core::Hash::from_bytes([9; 32]);
    }));
}
#[test]
fn consensus_rejects_beneficiary_claim_without_relative_lock_or_with_wrong_payout() {
    let (_, mut r) = fixture("deadManSwitch");
    let p = prepare(&r).unwrap();
    live(&mut r, &p);
    r.action = "claim".into();
    r.current_daa = 3202;
    r.sender = r.terms.beneficiary.clone();
    let secret = format!("private:{}", "02".repeat(32));
    assert!(rejects_mutated_transaction(&secret, &r, |tx| tx.inputs
        [0]
    .sequence = 0));
    let wrong = derive_address(&format!("private:{}", "01".repeat(32))).unwrap();
    assert!(rejects_mutated_transaction(&secret, &r, |tx| tx.outputs
        [0]
    .script_public_key =
        kaspa_txscript::pay_to_address_script(&wrong)));
}
