//! Read-only probe for integration checks; takes public name/owner data only.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(
        args.len(),
        4,
        "usage: dotk_derive BARE_NAME OWNER_TYPE OWNER_HEX"
    );
    let request = kaspa_secure_core::dotk::Request {
        name: args[1].clone(),
        owner_type: args[2].parse().expect("owner type"),
        owner: args[3].clone(),
    };
    println!(
        "{}",
        serde_json::to_string(&kaspa_secure_core::dotk::derive(&request).expect("valid deed"))
            .unwrap()
    );
}
