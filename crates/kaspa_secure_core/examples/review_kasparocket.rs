//! Read-only compatibility check. Reads a public unsigned plan request on stdin.
use std::io::{self, Read};
fn main() {
    let mut text = String::new();
    io::stdin().read_to_string(&mut text).unwrap();
    let request: kaspa_secure_core::PsktRequest = serde_json::from_str(&text).unwrap();
    let review = kaspa_secure_core::prepare_pskt(&request).expect("Mainnet plan must pass local review");
    let mut wrong_network = request.clone();
    wrong_network.profile = Some("kasparocket-testnet-v1".into());
    assert!(kaspa_secure_core::prepare_pskt(&wrong_network).is_err());
    let mut altered = request.clone();
    altered.trade_summary.as_mut().unwrap()["partnerFeeSompi"] = serde_json::json!("1");
    assert!(kaspa_secure_core::prepare_pskt(&altered).is_err());
    let mut altered = request.clone();
    altered.sign_inputs[0].expected_sighash = Some("00".repeat(32));
    assert!(kaspa_secure_core::prepare_pskt(&altered).is_err());
    println!("Mainnet plan, network binding, fee binding and sighash mutation checks passed: {}", review.transaction_id);
    if std::env::args().any(|arg| arg == "--json") {
        println!("{}", serde_json::to_string(&review).unwrap());
    }
}
