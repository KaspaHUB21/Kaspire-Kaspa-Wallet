//! `kusdt-tx <command>`: reads one JSON request on stdin, writes one JSON
//! answer on stdout. On failure it writes `{"error": "..."}` and exits 1.
//! See `kusdt_kaspa::api::COMMANDS` for the commands.

use std::io::Read;

use serde_json::json;

fn main() {
    let command = std::env::args().nth(1).unwrap_or_default();
    let mut input = String::new();
    if command != "template" {
        if let Err(e) = std::io::stdin().read_to_string(&mut input) {
            println!("{}", json!({ "error": format!("reading stdin: {e}") }));
            std::process::exit(1);
        }
    }
    match kusdt_kaspa::api::run(&command, &input) {
        Ok(value) => println!("{value}"),
        Err(error) => {
            println!("{}", json!({ "error": error }));
            std::process::exit(1);
        }
    }
}
