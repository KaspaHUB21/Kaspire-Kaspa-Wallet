use std::io::{self, Read};
fn main() {
    let mut raw = String::new();
    if io::stdin().take(8193).read_to_string(&mut raw).is_err() || raw.len() > 8192 {
        eprintln!("invalid descriptor input");
        std::process::exit(1);
    }
    match kaspa_secure_core::describe_dotk_market_json(&raw) {
        Ok(output) => println!("{output}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
