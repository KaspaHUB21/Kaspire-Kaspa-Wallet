use crate::covenant_wyrm::{compile_genesis, WyrmGenesisState, WyrmState};
use crate::kcc20::{simulate_all, submit_json_v1, wrpc_safe_json};
use crate::transaction::{parse_utxos, Spendable};
use crate::{controls_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version as AddressVersion};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    constants::TX_VERSION_TOCCATA,
    hashing::sighash_type::SIG_HASH_ALL,
    mass::{units::ComputeBudget, ContextualMasses, Mass, MassCalculator},
    sign::sign_input,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, GenesisCovenantGroup, SignableTransaction, Transaction, TransactionInput,
        TransactionOutput,
    },
};
use kaspa_txscript::{
    extract_script_pub_key_address, pay_to_address_script, pay_to_script_hash_script,
    script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};

const WYRM_RESERVE_SOMPI: u64 = 100_000_000;
const DUST_SOMPI: u64 = 10_000;
const FUNDING_COMPUTE_BUDGET: u16 = 10;
const STORAGE_LIMIT_PERCENT: u64 = 85;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WyrmGenesisRequest {
    pub sender: String,
    pub serial: u16,
    pub element: u8,
    pub fee_rate: f64,
    pub funding_utxos_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedWyrmGenesis {
    pub sender: String,
    pub serial: u16,
    pub element: u8,
    pub covenant_id: String,
    pub template_hash: String,
    pub reserve_sompi: u64,
    pub fee_sompi: u64,
    pub mass: u64,
    pub storage_mass: u64,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedWyrmGenesis {
    pub transaction_id: String,
    pub covenant_id: String,
    pub output_address: String,
    pub script_public_key: String,
    pub value_sompi: u64,
    pub state: WyrmState,
    pub submit_json: String,
    pub wrpc_json: String,
    pub fee_sompi: u64,
    pub review_hash: String,
}

struct Built {
    tx: Transaction,
    funding: Spendable,
    review: PreparedWyrmGenesis,
}

pub fn prepare(request: &WyrmGenesisRequest) -> Result<PreparedWyrmGenesis> {
    Ok(build(request)?.review)
}

pub fn sign(
    secret: &str,
    request: &WyrmGenesisRequest,
    approved_review_hash: &str,
) -> Result<SignedWyrmGenesis> {
    if !controls_address(secret, &request.sender)? {
        return Err(CoreError::InvalidRequest(
            "key does not control Wyrm genesis sender".into(),
        ));
    }
    let mut built = build(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let populated =
        SignableTransaction::with_entries(built.tx.clone(), vec![built.funding.entry.clone()]);
    let signature = sign_input(
        &populated.as_verifiable(),
        0,
        &*derive_key(secret)?,
        SIG_HASH_ALL,
    );
    // `sign_input` already returns the complete P2PK signature script
    // (`OP_DATA_65 <64-byte Schnorr signature> <sighash type>`). Wrapping it
    // in another data push produces a malformed signature at consensus.
    built.tx.inputs[0].signature_script = signature;
    built.tx.finalize();
    simulate_all(&built.tx, &[built.funding.entry.clone()])?;
    let output = &built.tx.outputs[0];
    let output_address = extract_script_pub_key_address(&output.script_public_key, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?
        .to_string();
    Ok(SignedWyrmGenesis {
        transaction_id: built.tx.id().to_string(),
        covenant_id: built.review.covenant_id.clone(),
        output_address,
        script_public_key: hex::encode(output.script_public_key.script()),
        value_sompi: output.value,
        state: WyrmState::genesis(WyrmGenesisState {
            owner: owner_key(
                &Address::try_from(request.sender.as_str())
                    .map_err(|_| CoreError::InvalidAddress)?,
            )?,
            serial: request.serial,
            element: request.element,
        }),
        submit_json: submit_json_v1(&built.tx)?,
        wrpc_json: wrpc_safe_json(&built.tx, &[built.funding.entry.clone()])?,
        fee_sompi: built.review.fee_sompi,
        review_hash: built.review.review_hash,
    })
}

fn owner_key(address: &Address) -> Result<[u8; 32]> {
    if address.prefix != Prefix::Mainnet
        || address.version != AddressVersion::PubKey
        || address.payload.len() != 32
    {
        return Err(CoreError::InvalidRequest(
            "Wyrm genesis requires a Mainnet P2PK wallet".into(),
        ));
    }
    address
        .payload
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidAddress)
}

fn build(request: &WyrmGenesisRequest) -> Result<Built> {
    if !request.fee_rate.is_finite() || !(100.0..=10_000.0).contains(&request.fee_rate) {
        return Err(CoreError::InvalidRequest(
            "Wyrm fee rate is out of range".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let compiled = compile_genesis(WyrmGenesisState {
        owner: owner_key(&sender)?,
        serial: request.serial,
        element: request.element,
    })?;
    let template_hash = hex::encode(compiled.template_hash());
    let wyrm_script = pay_to_script_hash_script(&compiled.script);
    let mut funding = parse_utxos(&request.funding_utxos_json, &sender)?;
    funding.sort_by_key(|item| item.entry.amount);
    let calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let limits = MAINNET_PARAMS.mempool_block_mass_limits().after();
    let storage_target = limits.storage.saturating_mul(STORAGE_LIMIT_PERCENT) / 100;
    for selected in funding {
        let mut fee = 0u64;
        for _ in 0..8 {
            let Some(change) = selected
                .entry
                .amount
                .checked_sub(WYRM_RESERVE_SOMPI)
                .and_then(|v| v.checked_sub(fee))
            else {
                break;
            };
            if change < DUST_SOMPI {
                break;
            }
            let input = TransactionInput::new_with_mass(
                selected.outpoint,
                vec![],
                0,
                ComputeCommit::ComputeBudget(ComputeBudget(FUNDING_COMPUTE_BUDGET)),
            );
            let mut tx = Transaction::new(TX_VERSION_TOCCATA, vec![input], vec![TransactionOutput::new(WYRM_RESERVE_SOMPI, wyrm_script.clone()), TransactionOutput::new(change, pay_to_address_script(&sender))], 0, SUBNETWORK_ID_NATIVE, 0, serde_json::to_vec(&json!({"p":"gothdag-covenant-wyrm-v1","action":"genesis","serial":request.serial,"element":request.element,"owner":request.sender})).map_err(|_| CoreError::Serialization)?);
            tx.populate_genesis_covenants(&[GenesisCovenantGroup::new(0, vec![0])])
                .map_err(|e| CoreError::Transaction(e.to_string()))?;
            tx.inputs[0].signature_script = ScriptBuilder::new()
                .add_data(&[0u8; 65])
                .map_err(|e| CoreError::Transaction(e.to_string()))?
                .drain();
            let populated =
                SignableTransaction::with_entries(tx.clone(), vec![selected.entry.clone()]);
            let non_contextual = calculator.calc_non_contextual_masses(&tx);
            let contextual = calculator
                .calc_contextual_masses(&populated.as_verifiable())
                .ok_or_else(|| {
                    CoreError::Transaction("Wyrm storage mass cannot be calculated".into())
                })?;
            let cofactors = MAINNET_PARAMS.mempool_block_mass_cofactors().after();
            let transient =
                (non_contextual.transient_mass as f64 * cofactors.transient).ceil() as u64;
            let mass = Mass::new(
                non_contextual,
                ContextualMasses::new(contextual.storage_mass),
            )
            .normalized_max(&cofactors);
            if mass > limits.reference() || contextual.storage_mass > storage_target {
                break;
            }
            let required_fee = (request.fee_rate
                * non_contextual.compute_mass.max(transient) as f64)
                .ceil() as u64;
            if fee < required_fee {
                fee = required_fee;
                continue;
            }
            tx.inputs[0].signature_script.clear();
            tx.set_storage_mass(contextual.storage_mass);
            tx.finalize();
            let covenant_id = tx.outputs[0]
                .covenant
                .ok_or_else(|| CoreError::Transaction("missing Wyrm covenant binding".into()))?
                .covenant_id
                .to_string();
            let review_value = json!({"network":"kaspa:mainnet","profile":"covenant-wyrm-genesis-v1","sender":request.sender,"serial":request.serial,"element":request.element,"covenantId":covenant_id,"templateHash":template_hash,"reserveSompi":WYRM_RESERVE_SOMPI,"feeSompi":fee,"mass":mass,"storageMass":contextual.storage_mass,"transactionId":tx.id().to_string()});
            let review_hash = hex::encode(Sha256::digest(
                serde_json::to_vec(&review_value).map_err(|_| CoreError::Serialization)?,
            ));
            return Ok(Built {
                tx,
                funding: selected,
                review: PreparedWyrmGenesis {
                    sender: request.sender.clone(),
                    serial: request.serial,
                    element: request.element,
                    covenant_id,
                    template_hash: template_hash.clone(),
                    reserve_sompi: WYRM_RESERVE_SOMPI,
                    fee_sompi: fee,
                    mass,
                    storage_mass: contextual.storage_mass,
                    review_hash,
                },
            });
        }
    }
    Err(CoreError::InsufficientFunds)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_sender_before_signing() {
        let r = WyrmGenesisRequest {
            sender: "invalid".into(),
            serial: 1,
            element: 0,
            fee_rate: 100.0,
            funding_utxos_json: "[]".into(),
        };
        assert!(prepare(&r).is_err());
    }
}
