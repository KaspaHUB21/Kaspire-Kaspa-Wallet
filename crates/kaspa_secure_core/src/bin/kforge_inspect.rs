//! Read-only replay of captured, unsigned public prepare responses.
use serde_json::{Value, json};
use std::io::Read;
fn main() {
    let path = std::env::args().nth(1).expect("unsigned capture path");
    if path == "--stdin" {
        let mut text = String::new();
        std::io::stdin().take(200_000).read_to_string(&mut text).unwrap();
        let r: kaspa_secure_core::PsktRequest = serde_json::from_str(&text).unwrap();
        assert!(matches!(r.profile.as_deref(), Some("kforge-mainnet-swap-v1" | "kforge-tn10-swap-v1")));
        match kaspa_secure_core::prepare_pskt(&r) {
            Ok(v) => println!("{}", serde_json::to_string(&v).unwrap()),
            Err(e) => {eprintln!("{e}");std::process::exit(1);}
        }
        return;
    }
    let data: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let network = data["registry"]["network"].as_str().unwrap();
    assert!(["mainnet", "testnet-10"].contains(&network));
    for (name, row) in data["trades"].as_object().unwrap() {
        let response = &row["response"];
        let t = &row["token"];
        let buy = name.ends_with("buy");
        let pool = name.starts_with("pool");
        let buy_budget = if buy {Some(if pool {row["body"]["kas"].clone()}else{response["cost"].clone()})}else{None};
        let amount = if pool {
            if buy {
                &row["body"]["kas"]
            } else {
                &row["body"]["tokens"]
            }
        } else {
            &row["body"]["qty"]
        };
        let wallet = row.get("wallet").unwrap_or(&data["wallet"]);
        let existing = response["mergedInto"]["amount"].as_u64().or_else(|| {
            data["wallets"][wallet.as_str()?]["holdings"].as_array()?.iter()
                .find(|h|h["tokenCovId"]==t["tokenCovId"])?["amount"].as_u64()
        }).unwrap_or(0);
        let r=serde_json::from_value(json!({"sender":wallet,"profile":if network=="mainnet"{"kforge-mainnet-swap-v1"}else{"kforge-tn10-swap-v1"},"tokenId":t["tokenCovId"],"lpCovenantId":if pool{&t["pool"]["poolCovId"]}else{&t["rungCovId"]},"ticker":t["ticker"],"side":if buy{"buy"}else{"sell"},"tradeSummary":{"network":network,"market":t,"amount":amount,"maximumDebit":"4500000000000000","minimumOut":"1","buyBudgetSompi":buy_budget,"existingAmount":existing,"leftover":response["leftover"].as_u64().unwrap_or(0)},"txJsonString":response["txJson"],"signInputs":[{"index":response["inputIndex"],"sighashType":1,"expectedSighash":response["sighash"]}],"scripts":[]})).unwrap();
        match kaspa_secure_core::prepare_pskt(&r) {
            Ok(v) => println!("{name}: {}", v.trade_summary.unwrap()["verified"]),
            Err(e) => {
                eprintln!("{name}: {e}");
                std::process::exit(1);
            }
        }
    }
}
