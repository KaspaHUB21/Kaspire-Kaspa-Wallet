//! kUSDT on Kaspa L1: the covenant contracts, their compiled artifact, the
//! protocol digests and the transaction builders.

use std::path::{Path, PathBuf};

use argent_artifact::Artifact;

pub mod api;
pub mod hex;
pub mod model;
pub mod pool;
pub mod protocol;
pub mod tx;

/// The repository's `bridge/kaspa` directory.
pub fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Compiles `contracts/<file>` into `build/<out>` and returns its artifact.
#[cfg(feature = "compiler")]
pub fn build_contract(file: &str, out: &str) -> Result<Artifact, Box<dyn std::error::Error>> {
    let root = crate_root();
    Ok(argent::build_file(root.join("contracts").join(file), root.join("build").join(out))?)
}

/// Compiles the kUSDT token app.
#[cfg(feature = "compiler")]
pub fn kusdt_artifact() -> Result<Artifact, Box<dyn std::error::Error>> {
    build_contract("kusdt.ag", "kusdt")
}

/// Compiles the KAS ⇄ kUSDT pool app.
#[cfg(feature = "compiler")]
pub fn pool_artifact() -> Result<Artifact, Box<dyn std::error::Error>> {
    build_contract("pool.ag", "pool")
}

/// Splits a compiled contract into the KCC-1 view that wallets match: the
/// prefix up to and including the embedded template hash, and the suffix
/// after the encoded state.
pub fn kcc20_wallet_template(artifact: &Artifact, contract: &str) -> Option<(Vec<u8>, Vec<u8>)> {
    let compiled = &artifact.sil_abi.contracts.get(contract)?.compiled;
    let span = &compiled.state_span;
    let bytecode = &compiled.bytecode;
    let mut prefix = bytecode[..span.offset].to_vec();
    prefix.push(0x20);
    prefix.extend_from_slice(compiled.template_hash.as_ref());
    let suffix = bytecode[span.offset + span.len..].to_vec();
    Some((prefix, suffix))
}

pub fn read_json(path: &Path) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    Ok(serde_json::from_str(&std::fs::read_to_string(path)?)?)
}
