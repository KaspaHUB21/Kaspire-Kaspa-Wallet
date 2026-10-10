use std::io::{self, Read};
fn main() {
    let mut raw = String::new();
    io::stdin()
        .take(512 * 1024 + 1)
        .read_to_string(&mut raw)
        .expect("read request");
    let result = (|| {
        let v: serde_json::Value = serde_json::from_str(&raw)?;
        if v["action"] == "normalize-transport" {
            Ok::<_, Box<dyn std::error::Error>>(serde_json::json!({"signedBuyerPskt":
                kaspa_secure_core::normalize_kaspacom_transport_json(
                    v["signedBuyerPskt"].as_str().unwrap_or(""), v["address"].as_str().unwrap_or(""))?
            }).to_string())
        } else if v["action"] == "authenticate" {
            kaspa_secure_core::verify_kaspacom_login(
                v["address"].as_str().unwrap_or(""),
                v["message"].as_str().unwrap_or(""),
                v["signature"].as_str().unwrap_or(""),
            )?;
            Ok::<_, Box<dyn std::error::Error>>("{\"valid\":true}".to_string())
        } else {
            Ok(kaspa_secure_core::prepare_kaspacom_market_json(&raw)?)
        }
    })();
    match result {
        Ok(r) => println!("{r}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
