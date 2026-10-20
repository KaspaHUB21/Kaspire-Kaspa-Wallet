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
    // Exercise both compute- and storage-dominated transactions with complete
    // signed witnesses, different input counts, fee rates and recipient types.
    for (count, value, rate, max, script_hash) in [
        (1, 100_000_000_000u64, 1.0, false, false),
        (1, 100_000_000_000, 2.5, true, false),
        (2, 1_000_000_000, 1000.0, false, true),
        (2, 1_000_000_000, 1.0, true, true),
        (10, 1_000_000_000, 2.5, false, false),
        (10, 1_000_000_000, 100.0, true, false),
    ] {
        let mut r = request.clone();
        let more = (0..count).map(|i| {
            let mut row = rows[i % 2].clone();
            row["outpoint"]["transactionId"] = json!(format!("{:064x}", i + 100));
            row["utxoEntry"]["amount"] = json!(value.to_string());
            row
        }).collect::<Vec<_>>();
        r.utxos_json = json!(more).to_string(); r.fee_rate = rate;
        r.signers.truncate(count.min(2));
        r.send_all = max; r.amount_sompi = if max { 0 } else { 100_000_000 };
        if script_hash { r.recipient = derive(secret, 0, 5, 1).unwrap()[0].address.clone(); }
        let review = prepare(secret, &r).unwrap();
        let mut saved = sign(secret, &r, review["reviewHash"].as_str().unwrap()).unwrap();
        saved["request"] = serde_json::to_value(&r).unwrap();
        cases.push(json!({"request":r,"review":review,"saved":saved}));
    }
    println!(
        "{}",
        json!({"secret":secret, "addresses":signers, "rows":rows, "cases":cases})
    );
}
