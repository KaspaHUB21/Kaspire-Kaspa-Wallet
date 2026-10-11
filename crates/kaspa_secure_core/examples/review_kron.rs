use std::io::{self, Read};
fn main() {
    let mut text = String::new();
    io::stdin().read_to_string(&mut text).unwrap();
    let request: kaspa_secure_core::PsktRequest = serde_json::from_str(&text).unwrap();
    match kaspa_secure_core::prepare_pskt(&request) {
        Ok(review) => {
            let mut altered=request.clone();
            altered.trade_summary.as_mut().unwrap()["rawAmount"]=serde_json::json!("1");
            assert!(kaspa_secure_core::prepare_pskt(&altered).is_err());
            let mut altered=request.clone();
            let mut tx:serde_json::Value=serde_json::from_str(&altered.tx_json_string).unwrap();
            tx["payload"]=serde_json::json!(hex::encode(b"kron:r:attacker"));
            altered.tx_json_string=tx.to_string();
            assert!(kaspa_secure_core::prepare_pskt(&altered).is_err());
            if std::env::args().any(|a| a=="--simulate") {
                // Fixed public test key; synthetic funding only. Never broadcasts.
                match kaspa_secure_core::sign_pskt(&format!("private:{}", "11".repeat(32)), &request, &review.review_hash) {
                    Ok(signed)=>println!("Local VM passed: {}",signed.transaction_id),
                    Err(error)=>{eprintln!("{error}");std::process::exit(1);}
                }
            } else {println!("Review and mutation checks passed: {}",review.transaction_id);}
        },
        Err(error) => { eprintln!("{error}"); std::process::exit(1); }
    }
}
