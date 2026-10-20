//! Deterministic public test keys ONLY. No network or real wallet access.
use kaspa_secure_core::{
    covenant_vault::{self, Cell, Request, Terms},
    import_private_key, vault_recovery,
};
use serde_json::{json, Value};
fn main() {
    let password = b"Vault cross-platform fixture 2026!";
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("open") {
        let sealed = std::fs::read_to_string(&args[2]).unwrap();
        println!("{}", vault_recovery::open(password, &sealed).unwrap());
        return;
    }
    let secret = format!("private:{}", "01".repeat(32));
    let beneficiary_secret = format!("private:{}", "02".repeat(32));
    let owner = import_private_key(&"01".repeat(32))
        .unwrap()
        .address
        .clone();
    let beneficiary = import_private_key(&"02".repeat(32))
        .unwrap()
        .address
        .clone();
    let address = kaspa_addresses::Address::try_from(owner.as_str()).unwrap();
    let spk = kaspa_txscript::pay_to_address_script(&address);
    let funding = json!([{"address":owner,"outpoint":{"transactionId":"ab".repeat(32),"index":0},"utxoEntry":{"amount":"10000000000","blockDaaScore":"1000","isCoinbase":false,"scriptPublicKey":{"scriptPublicKey":hex::encode(spk.script())}}}]).to_string();
    let mut cases: Vec<Value> = vec![];
    for kind in ["timeLock", "deadManSwitch"] {
        let mut r = Request {
            action: "create".into(),
            sender: owner.clone(),
            terms: Terms {
                kind: kind.into(),
                owner: owner.clone(),
                beneficiary: if kind == "timeLock" {
                    String::new()
                } else {
                    beneficiary.clone()
                },
                limit_daa: if kind == "timeLock" { 5000 } else { 1200 },
                instance: "03".repeat(32),
                name: "Cross-platform vault".into(),
            },
            amount_sompi: 100_000_000,
            current_daa: 2000,
            fee_rate: 100.0,
            funding_utxos_json: funding.clone(),
            cell: None,
        };
        let review = covenant_vault::prepare(&r).unwrap();
        cases.push(json!({"request":r,"review":review,"secret":secret}));
        r.cell = Some(Cell {
            covenant_id: review["covenantId"].as_str().unwrap().into(),
            transaction_id: review["transactionId"].as_str().unwrap().into(),
            index: 0,
            value_sompi: r.amount_sompi,
            block_daa_score: 2001,
            script_public_key: review["record"]["scriptPublicKey"].as_str().unwrap().into(),
        });
        if kind == "deadManSwitch" {
            r.action = "heartbeat".into();
            r.current_daa = 2100;
            cases.push(
                json!({"request":r,"review":covenant_vault::prepare(&r).unwrap(),"secret":secret}),
            );
            r.action = "claim".into();
            r.sender = beneficiary.clone();
            r.current_daa = 3202;
            r.funding_utxos_json = "[]".into();
            cases.push(json!({"request":r,"review":covenant_vault::prepare(&r).unwrap(),"secret":beneficiary_secret}));
        } else {
            r.action = "release".into();
            r.current_daa = 5001;
            r.funding_utxos_json = "[]".into();
            cases.push(
                json!({"request":r,"review":covenant_vault::prepare(&r).unwrap(),"secret":secret}),
            );
        }
    }
    let record = cases[0]["review"]["record"].clone();
    println!(
        "{}",
        json!({"cases":cases,"password":String::from_utf8_lossy(password),"record":record,"sealed":vault_recovery::seal(password,&record.to_string()).unwrap()})
    );
}
