use std::io::{self, Read};
fn main() {
    let mut raw = String::new();
    io::stdin()
        .take(512 * 1024 + 1)
        .read_to_string(&mut raw)
        .expect("read request");
    match kaspa_secure_core::prepare_nft_market_json(&raw) {
        Ok(result) => println!("{result}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
