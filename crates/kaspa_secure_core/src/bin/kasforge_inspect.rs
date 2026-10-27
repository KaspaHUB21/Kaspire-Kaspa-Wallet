//! Unsigned TN10 order diagnostic. No key or signing entry point.
use std::io::{self, Read};
fn main() {
    let mut raw = String::new();
    io::stdin()
        .take(1024 * 1024 + 1)
        .read_to_string(&mut raw)
        .expect("request");
    let result = (|| -> Result<String, String> {
        let r: kaspa_secure_core::PsktRequest =
            serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        if r.profile.as_deref() != Some("kasforge-tn10-order-v1") {
            return Err("Forge profile required".into());
        }
        serde_json::to_string(&kaspa_secure_core::prepare_pskt(&r).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())
    })();
    match result {
        Ok(s) => println!("{s}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
