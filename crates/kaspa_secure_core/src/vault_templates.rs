//! Host-compiled SilverScript templates. No compiler code/older consensus WASM
//! exports are linked into the browser signing module.
use crate::{CoreError, Result};
use kaspa_txscript::script_builder::ScriptBuilder;
pub struct PortableCompiled {
    pub bytecode: Vec<u8>,
    pub dispatch_tags: std::collections::BTreeMap<String, [u8; 4]>,
    state_start: usize,
    state_end: usize,
}
impl PortableCompiled {
    pub fn template_hash(&self) -> [u8; 32] {
        let prefix = &self.bytecode[..self.state_start];
        let suffix = &self.bytecode[self.state_end..];
        blake3::Hasher::new()
            .update(&(prefix.len() as i64).to_le_bytes())
            .update(prefix)
            .update(&(suffix.len() as i64).to_le_bytes())
            .update(suffix)
            .finalize()
            .into()
    }
}
include!(concat!(env!("OUT_DIR"), "/vault_templates.rs"));
pub fn materialize(
    kind: &str,
    owner: &[u8],
    beneficiary: &[u8],
    limit: i64,
    instance: &[u8],
) -> Result<PortableCompiled> {
    match kind {
        "timeLock" => materialize_time_lock(owner, beneficiary, limit, instance),
        "deadManSwitch" => materialize_dead_man_switch(owner, beneficiary, limit, instance),
        _ => Err(CoreError::InvalidRequest("Invalid vault type".into())),
    }
}
