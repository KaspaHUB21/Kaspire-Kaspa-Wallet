use kaspa_secure_core::{inspect_covenant_wyrm_state, WyrmState};
use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("failed to read Wyrm state");
        std::process::exit(2);
    }
    let state: WyrmState = match serde_json::from_str(&input) {
        Ok(state) => state,
        Err(_) => {
            eprintln!("invalid Wyrm state JSON");
            std::process::exit(2);
        }
    };
    match inspect_covenant_wyrm_state(state).and_then(|value| {
        serde_json::to_string(&value).map_err(|_| kaspa_secure_core::CoreError::Serialization)
    }) {
        Ok(output) => println!("{output}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
