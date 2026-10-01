use crate::{CoreError, Result};
use kaspa_addresses::Prefix;
use kaspa_txscript::{extract_script_pub_key_address, pay_to_script_hash_script};
use serde::{Deserialize, Serialize};
use silverscript_lang::{
    ast::Expr,
    compiler::{compile_contract, CompileOptions, CompiledContract},
};

const SOURCE: &str = include_str!("covenant_wyrm.sil");
pub const ELEMENT_COUNT: u8 = 13;
pub const GENESIS_SUPPLY_CAP: u16 = 287;

#[derive(Debug, Clone, Copy)]
pub struct WyrmGenesisState {
    pub owner: [u8; 32],
    pub serial: u16,
    pub element: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WyrmState {
    pub owner: [u8; 32],
    pub serial: u16,
    pub element: u8,
    pub phase: u8,
    pub warmed: bool,
    pub care_points: u32,
    pub active_days: u32,
    pub growth_stage: u8,
    pub specialization: u8,
    pub name_hash: [u8; 32],
    pub anchor_daa: u64,
    pub sleep_started_daa: u64,
    pub bone_feeds: u32,
    pub blood_feeds: u32,
    pub moon_feeds: u32,
    pub teal_feeds: u32,
    pub night_feeds: u32,
}

impl WyrmState {
    pub fn genesis(state: WyrmGenesisState) -> Self {
        Self {
            owner: state.owner,
            serial: state.serial,
            element: state.element,
            phase: 0,
            warmed: false,
            care_points: 0,
            active_days: 0,
            growth_stage: 0,
            specialization: 0,
            name_hash: [0; 32],
            anchor_daa: 0,
            sleep_started_daa: 0,
            bone_feeds: 0,
            blood_feeds: 0,
            moon_feeds: 0,
            teal_feeds: 0,
            night_feeds: 0,
        }
    }
}

pub fn compile_genesis(state: WyrmGenesisState) -> Result<CompiledContract<'static>> {
    compile_state(WyrmState::genesis(state))
}

pub fn compile_state(state: WyrmState) -> Result<CompiledContract<'static>> {
    if state.serial == 0
        || state.serial > GENESIS_SUPPLY_CAP
        || state.element >= ELEMENT_COUNT
        || !matches!(state.phase, 0 | 1 | 2 | 3 | 4)
        || state.growth_stage > 3
        || state.specialization > 5
        || (state.phase == 0 && state.anchor_daa != 0)
        || (state.phase == 3 && state.sleep_started_daa < state.anchor_daa)
        || (state.phase != 3 && state.sleep_started_daa != 0)
    {
        return Err(CoreError::InvalidRequest(
            "invalid Covenant Wyrm state".into(),
        ));
    }
    let anchor_daa = i64::try_from(state.anchor_daa)
        .map_err(|_| CoreError::InvalidRequest("Wyrm DAA score exceeds signed range".into()))?;
    let sleep_started_daa = i64::try_from(state.sleep_started_daa).map_err(|_| {
        CoreError::InvalidRequest("Wyrm sleep DAA score exceeds signed range".into())
    })?;
    compile_contract(
        SOURCE,
        &[
            Expr::bytes(state.owner.to_vec()),
            Expr::int(i64::from(state.serial)),
            Expr::byte(state.element),
            Expr::byte(state.phase),
            Expr::bool(state.warmed),
            Expr::int(i64::from(state.care_points)),
            Expr::int(i64::from(state.active_days)),
            Expr::byte(state.growth_stage),
            Expr::byte(state.specialization),
            Expr::bytes(state.name_hash.to_vec()),
            Expr::int(anchor_daa),
            Expr::int(sleep_started_daa),
            Expr::int(i64::from(state.bone_feeds)),
            Expr::int(i64::from(state.blood_feeds)),
            Expr::int(i64::from(state.moon_feeds)),
            Expr::int(i64::from(state.teal_feeds)),
            Expr::int(i64::from(state.night_feeds)),
        ],
        CompileOptions::default(),
    )
    .map_err(|error| CoreError::Transaction(format!("Covenant Wyrm compile failed: {error}")))
}

pub fn inspect_state(state: WyrmState) -> Result<WyrmStateInspection> {
    let compiled = compile_state(state)?;
    let script_public_key = pay_to_script_hash_script(&compiled.script);
    let output_address = extract_script_pub_key_address(&script_public_key, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?
        .to_string();
    Ok(WyrmStateInspection {
        template_hash: hex::encode(compiled.template_hash()),
        script_public_key: hex::encode(script_public_key.script()),
        output_address,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WyrmStateInspection {
    pub template_hash: String,
    pub script_public_key: String,
    pub output_address: String,
}

pub fn template_hash() -> Result<String> {
    Ok(hex::encode(
        compile_genesis(WyrmGenesisState {
            owner: [0; 32],
            serial: 1,
            element: 0,
        })?
        .template_hash(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiles_singleton_lifecycle_with_stable_template() {
        let fire = compile_genesis(WyrmGenesisState {
            owner: [1; 32],
            serial: 1,
            element: 0,
        })
        .unwrap();
        let nuclear = compile_genesis(WyrmGenesisState {
            owner: [2; 32],
            serial: 287,
            element: 12,
        })
        .unwrap();
        assert_eq!(fire.template_hash(), nuclear.template_hash());
        assert!(fire
            .abi
            .iter()
            .any(|entry| entry.name.contains("transition")));
    }

    #[test]
    fn rejects_out_of_range_genesis_state() {
        assert!(compile_genesis(WyrmGenesisState {
            owner: [0; 32],
            serial: 0,
            element: 0
        })
        .is_err());
        assert!(compile_genesis(WyrmGenesisState {
            owner: [0; 32],
            serial: 1,
            element: 13
        })
        .is_err());
    }
}
