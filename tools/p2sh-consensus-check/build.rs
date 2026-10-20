use std::{env, fs, path::PathBuf, process::Command};

const REV: &str = "01b532e8b553523216471682649693af92f0fd16";
fn main() {
    println!("cargo:rerun-if-env-changed=RUSTY_KASPA_SOURCE");
    let source =
        env::var("RUSTY_KASPA_SOURCE").expect("set RUSTY_KASPA_SOURCE to the v2.1.0 git checkout");
    let destination = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("node_validator");
    fs::create_dir_all(&destination).unwrap();
    for name in [
        "mod.rs",
        "errors.rs",
        "tx_validation_in_header_context.rs",
        "tx_validation_in_isolation.rs",
        "tx_validation_in_utxo_context.rs",
    ] {
        // Read the pinned Git object, NOT a possibly modified working-tree file.
        let object = format!("{REV}:consensus/src/processes/transaction_validator/{name}");
        let result = Command::new("git")
            .args(["-C", &source, "show", &object])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "cannot read pinned official validator {name}"
        );
        fs::write(destination.join(name), result.stdout).unwrap();
    }
    println!("cargo:rustc-env=KASPIRE_NODE_VALIDATOR_REV={REV}");
}
