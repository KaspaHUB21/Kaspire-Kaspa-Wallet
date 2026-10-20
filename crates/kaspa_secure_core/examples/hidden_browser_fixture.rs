// Synthetic public test vector. Never fund addresses derived from this seed.
use kaspa_secure_core::{hidden_kas::*, import_wallet};
use serde_json::{json, Value};
fn main() {
    let secret = "mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    let signers = derive(secret, 0, 0, 2).unwrap();
    let rows: Vec<Value> = signers.iter().enumerate().map(|(i, a)| json!({
        "address": a.address, "outpoint": {"transactionId": format!("{:02x}", i + 1).repeat(32), "index": 0},
        "utxoEntry": {"amount": "1000000000", "blockDaaScore": "5000", "isCoinbase": false,
        "scriptPublicKey": {"version": 0, "scriptPublicKey": hex::encode(kaspa_txscript::pay_to_address_script(&kaspa_addresses::Address::try_from(a.address.as_str()).unwrap()).script())}}
    })).collect();
    let mut request = Request {
        descriptor: DESCRIPTOR.into(),
        recipient: import_wallet(secret.strip_prefix("mnemonic:").unwrap())
            .unwrap()
            .address
            .clone(),
        amount_sompi: 100000000,
        send_all: false,
        fee_rate: 100.0,
        signers: signers.clone(),
        change: derive(secret, 1, 0, 1).unwrap().remove(0),
        utxos_json: json!(rows).to_string(),
    };
    let mut cases = vec![];
    for max in [false, true] {
        request.send_all = max;
        request.amount_sompi = if max { 0 } else { 100000000 };
        let review = prepare(secret, &request).unwrap();
        let mut saved = sign(secret, &request, review["reviewHash"].as_str().unwrap()).unwrap();
        saved["request"] = serde_json::to_value(&request).unwrap();
        cases.push(json!({"request":request, "review":review, "saved":saved}));
    }
    println!(
        "{}",
        json!({"secret":secret, "addresses":signers, "rows":rows, "cases":cases})
    );
}
