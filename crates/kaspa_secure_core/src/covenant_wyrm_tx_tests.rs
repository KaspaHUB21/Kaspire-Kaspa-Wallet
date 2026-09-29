use crate::{derive_address, prepare_wyrm_genesis, sign_wyrm_genesis, WyrmGenesisRequest};
use kaspa_txscript::pay_to_address_script;
use serde_json::json;

fn fixture() -> (String, WyrmGenesisRequest) {
    let secret =
        "private:0000000000000000000000000000000000000000000000000000000000000001".to_string();
    let sender = derive_address(&secret).unwrap();
    let script = pay_to_address_script(&sender);
    let funding = json!([{
        "address": sender.to_string(),
        "outpoint": {"transactionId":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","index":0},
        "utxoEntry": {"amount":"10000000000","blockDaaScore":"1","isCoinbase":false,
            "scriptPublicKey":{"scriptPublicKey":hex::encode(script.script())}}
    }]).to_string();
    (
        secret,
        WyrmGenesisRequest {
            sender: sender.to_string(),
            serial: 1,
            element: 0,
            fee_rate: 100.0,
            funding_utxos_json: funding,
        },
    )
}

#[test]
fn builds_and_signs_real_genesis_covenant() {
    let (secret, request) = fixture();
    let prepared = prepare_wyrm_genesis(&request).unwrap();
    assert_eq!(prepared.serial, 1);
    assert_eq!(prepared.covenant_id.len(), 64);
    assert!(prepared.storage_mass > 0);
    let signed = sign_wyrm_genesis(&secret, &request, &prepared.review_hash).unwrap();
    assert_eq!(signed.covenant_id, prepared.covenant_id);
    assert!(signed.submit_json.contains("covenantId"));
    let submit: serde_json::Value = serde_json::from_str(&signed.submit_json).unwrap();
    let signature_script = submit["transaction"]["inputs"][0]["signatureScript"]
        .as_str()
        .unwrap();
    assert_eq!(signature_script.len(), 132);
    assert!(signature_script.starts_with("41"));
}

#[test]
fn review_hash_and_parameters_are_binding() {
    let (secret, request) = fixture();
    let prepared = prepare_wyrm_genesis(&request).unwrap();
    assert!(sign_wyrm_genesis(&secret, &request, "00").is_err());
    let mut altered = request.clone();
    altered.element = 7;
    assert!(sign_wyrm_genesis(&secret, &altered, &prepared.review_hash).is_err());
}
