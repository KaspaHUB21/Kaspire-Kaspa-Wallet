use crate::transaction::{parse_utxos, Spendable};
use crate::{derive_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Version as AddressVersion};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    constants::TX_VERSION_TOCCATA,
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{
        units::{ComputeBudget, Gram},
        ContextualMasses, Mass, MassCalculator,
    },
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, CovenantBinding, PopulatedTransaction, Transaction, TransactionId,
        TransactionInput, TransactionOutpoint, TransactionOutput, UtxoEntry, VerifiableTransaction,
    },
    Hash,
};
use kaspa_txscript::{
    caches::Cache, covenants::CovenantsContext, pay_to_address_script, pay_to_script_hash_script,
    script_builder::ScriptBuilder, EngineCtx, EngineFlags, TxScriptEngine,
};
use secp256k1::{Keypair, Message, SECP256K1};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use silverscript_lang::{
    ast::Expr,
    compiler::{
        compile_contract, struct_object, CompileOptions, CompiledContract, CovenantDeclCallOptions,
    },
};
use std::str::FromStr;

const KCC20_SOURCE: &str = include_str!("kcc20.sil");
const KCC20_MAX_INPUTS: usize = 2;
const KCC20_MAX_OUTPUTS: usize = 2;
// A two-cell leader executes two Schnorr checks and currently consumes about
// 210,278 script units. Budget 22 commits 229,999 units with safety margin.
const KCC20_COMPUTE_BUDGET: u16 = 22;
const FEE_COMPUTE_BUDGET: u16 = 10;
const DUST_LIMIT_SOMPI: u64 = 10_000;
const MIN_FEE_RATE: f64 = 100.0;
const MAX_FEE_RATE: f64 = 10_000.0;
const SIGNATURE_WITH_HASH_TYPE_LEN: usize = 65;
const STORAGE_LIMIT_SAFETY_PERCENT: u64 = 85;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Kcc20Cell {
    pub covenant_id: String,
    pub transaction_id: String,
    pub index: u32,
    pub value_sompi: u64,
    pub block_daa_score: u64,
    pub script_public_key: String,
    pub token_amount: u64,
    #[serde(default)]
    pub is_minter: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Kcc20TransferRequest {
    pub sender: String,
    pub recipient: String,
    pub covenant_id: String,
    pub ticker: String,
    pub amount: u64,
    pub decimals: u8,
    pub fee_rate: f64,
    pub template_hash: String,
    pub cells: Vec<Kcc20Cell>,
    pub funding_utxos_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedKcc20Transfer {
    pub sender: String,
    pub recipient: String,
    pub covenant_id: String,
    pub ticker: String,
    pub amount: u64,
    pub token_change: u64,
    pub locked_kas_sompi: u64,
    pub locked_kas_top_up_sompi: u64,
    pub locked_kas_released_sompi: u64,
    pub locked_kas_output_sompi: u64,
    pub fee_sompi: u64,
    pub mass: u64,
    pub compute_mass: u64,
    pub storage_mass: u64,
    pub storage_mass_commitment: u64,
    pub storage_mass_target: u64,
    pub transient_mass: u64,
    pub fee_mass: u64,
    pub covenant_input_count: usize,
    pub covenant_output_count: usize,
    pub compute_budget: u64,
    pub template_hash: String,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedKcc20Transfer {
    pub transaction_id: String,
    pub fee_sompi: u64,
    pub mass: u64,
    pub storage_mass: u64,
    pub submit_json: String,
    pub preflight_json: String,
    pub wrpc_json: String,
    pub review_hash: String,
}

struct BuiltKcc20 {
    transaction: Transaction,
    entries: Vec<UtxoEntry>,
    selected_cells: Vec<Kcc20Cell>,
    review: PreparedKcc20Transfer,
}

#[derive(Debug, Clone, Copy)]
struct MassBreakdown {
    effective: u64,
    compute: u64,
    storage: u64,
    storage_commitment: u64,
    transient: u64,
    fee: u64,
}

struct FundedKcc20 {
    transaction: Transaction,
    entries: Vec<UtxoEntry>,
    mass: MassBreakdown,
    fee: u64,
    locked_kas_top_up: u64,
    locked_kas_released: u64,
    locked_kas_output: u64,
}

pub fn kcc20_template_hash() -> Result<String> {
    let compiled = compile_state(&[0; 32], 1, false)?;
    Ok(hex::encode(compiled.template_hash()))
}

pub fn prepare_kcc20_transfer(request: &Kcc20TransferRequest) -> Result<PreparedKcc20Transfer> {
    Ok(build(request)?.review)
}

pub fn sign_kcc20_transfer(
    secret: &str,
    request: &Kcc20TransferRequest,
    approved_review_hash: &str,
) -> Result<SignedKcc20Transfer> {
    if derive_address(secret)?.to_string() != request.sender {
        return Err(CoreError::InvalidRequest(
            "key does not control the KCC20 sender".into(),
        ));
    }
    let mut built = build(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }

    let key = derive_key(secret)?;
    let keypair =
        Keypair::from_seckey_slice(SECP256K1, key.as_ref()).map_err(|_| CoreError::Derivation)?;
    let sender_owner = address_pubkey(
        &Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?,
    )?;
    let recipient_owner = address_pubkey(
        &Address::try_from(request.recipient.as_str()).map_err(|_| CoreError::InvalidAddress)?,
    )?;
    let selected_total = built
        .selected_cells
        .iter()
        .try_fold(0u64, |sum, cell| sum.checked_add(cell.token_amount))
        .ok_or_else(|| CoreError::InvalidRequest("KCC20 amount overflow".into()))?;
    let token_change = selected_total - request.amount;
    let output_states = state_array(
        &recipient_owner,
        request.amount,
        (token_change > 0).then_some((&sender_owner, token_change)),
    )?;

    let reused = SigHashReusedValuesUnsync::new();
    let populated = PopulatedTransaction::new(&built.transaction, built.entries.clone());
    // The transfer policy is executed by the covenant-group leader (input 0).
    // Every CHECKSIG inside that leader script therefore verifies the leader
    // input sighash, even when authorizing a state read from another member of
    // the group. Signing each member's own input index makes the second
    // signature fail inside the leader script.
    let leader_signature = sign_hash(&keypair, &populated, 0, &reused)?;
    let signatures = vec![leader_signature; built.selected_cells.len()];
    for index in 0..built.selected_cells.len() {
        let compiled = compile_state(
            &sender_owner,
            built.selected_cells[index].token_amount,
            false,
        )?;
        built.transaction.inputs[index].signature_script = covenant_sigscript(
            &compiled,
            if index == 0 {
                vec![
                    output_states.clone(),
                    signature_array(&signatures),
                    Expr::bytes((0..built.selected_cells.len() as u8).collect()),
                ]
            } else {
                vec![]
            },
            index == 0,
        )?;
    }

    let funding_index = built.selected_cells.len();
    let populated = PopulatedTransaction::new(&built.transaction, built.entries.clone());
    let funding_signature = sign_hash(&keypair, &populated, funding_index, &reused)?;
    built.transaction.inputs[funding_index].signature_script = ScriptBuilder::new()
        .add_data(&funding_signature)
        .map_err(|error| CoreError::Transaction(error.to_string()))?
        .drain();
    built
        .transaction
        .set_storage_mass(built.review.storage_mass_commitment);
    built.transaction.finalize();

    simulate_all(&built.transaction, &built.entries)?;
    let transaction_id = built.transaction.id().to_string();
    let submit_json = submit_json_v1(&built.transaction)?;
    let preflight_json = preflight_json(&built.transaction, &built.entries)?;
    let wrpc_json = wrpc_safe_json(&built.transaction, &built.entries)?;
    Ok(SignedKcc20Transfer {
        transaction_id,
        fee_sompi: built.review.fee_sompi,
        mass: built.review.mass,
        storage_mass: built.review.storage_mass_commitment,
        submit_json,
        preflight_json,
        wrpc_json,
        review_hash: built.review.review_hash,
    })
}

fn build(request: &Kcc20TransferRequest) -> Result<BuiltKcc20> {
    if request.amount == 0
        || request.decimals > 18
        || !request.fee_rate.is_finite()
        || !(MIN_FEE_RATE..=MAX_FEE_RATE).contains(&request.fee_rate)
        || request.ticker.trim().is_empty()
        || request.ticker.len() > 32
    {
        return Err(CoreError::InvalidRequest(
            "invalid KCC20 amount, metadata, or fee rate".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let recipient =
        Address::try_from(request.recipient.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if !request.sender.starts_with("kaspa:") || !request.recipient.starts_with("kaspa:") {
        return Err(CoreError::InvalidAddress);
    }
    let sender_owner = address_pubkey(&sender)?;
    let recipient_owner = address_pubkey(&recipient)?;
    let covenant_id = Hash::from_str(&request.covenant_id)
        .map_err(|_| CoreError::InvalidRequest("invalid covenant ID".into()))?;

    let local_template_hash = kcc20_template_hash()?;
    if request.template_hash.to_lowercase() != local_template_hash {
        return Err(CoreError::InvalidRequest(
            "KCC20 template is not the locally audited template".into(),
        ));
    }
    if request.cells.is_empty() || request.cells.len() > 64 {
        return Err(CoreError::InvalidRequest("invalid KCC20 cell set".into()));
    }
    let mut outpoints = std::collections::HashSet::with_capacity(request.cells.len());
    for cell in &request.cells {
        if !outpoints.insert((cell.transaction_id.to_lowercase(), cell.index)) {
            return Err(CoreError::InvalidRequest(
                "duplicate KCC20 cell outpoint".into(),
            ));
        }
    }
    let mut cells = request.cells.clone();
    cells.sort_by_key(|cell| cell.token_amount);
    for cell in &cells {
        validate_cell(cell, &sender_owner, covenant_id)?;
    }
    let selected_cells = select_cells(&cells, request.amount)?;
    let selected_total = selected_cells
        .iter()
        .try_fold(0u64, |sum, cell| sum.checked_add(cell.token_amount))
        .ok_or_else(|| CoreError::InvalidRequest("KCC20 amount overflow".into()))?;
    let token_change = selected_total - request.amount;
    let locked_kas_sompi = selected_cells
        .iter()
        .try_fold(0u64, |sum, cell| sum.checked_add(cell.value_sompi))
        .ok_or_else(|| CoreError::InvalidRequest("KCC20 cell value overflow".into()))?;
    let covenant_output_count = if token_change == 0 { 1 } else { 2 };
    let cell_values = vec![DUST_LIMIT_SOMPI; covenant_output_count];

    let mut funding = parse_utxos(&request.funding_utxos_json, &sender)?;
    funding.sort_by_key(|item| item.entry.amount);
    let template_funding = funding.first().ok_or(CoreError::InsufficientFunds)?;
    let mass_calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut transaction_template = make_transaction(
        &selected_cells,
        &sender,
        &recipient_owner,
        &sender_owner,
        request.amount,
        token_change,
        &cell_values,
        covenant_id,
        template_funding,
        DUST_LIMIT_SOMPI,
    )?;
    add_dummy_scripts(
        &mut transaction_template,
        &selected_cells,
        &sender_owner,
        &recipient_owner,
        request.amount,
        token_change,
    )?;
    let funding_input_index = selected_cells.len();
    let funding_output_index = transaction_template.outputs.len() - 1;
    let mass_limits = MAINNET_PARAMS.mempool_block_mass_limits().after();
    let mass_limit = mass_limits.reference();
    let storage_target = mass_limits
        .storage
        .saturating_mul(STORAGE_LIMIT_SAFETY_PERCENT)
        / 100;
    let mut best: Option<FundedKcc20> = None;

    for funding in &funding {
        let mut required_fee = 0u64;
        for _ in 0..64 {
            let Some(total_output_value) = locked_kas_sompi
                .checked_add(funding.entry.amount)
                .and_then(|value| value.checked_sub(required_fee))
            else {
                break;
            };
            let minimum_covenant_total =
                DUST_LIMIT_SOMPI.saturating_mul(covenant_output_count as u64);
            if total_output_value < minimum_covenant_total.saturating_add(DUST_LIMIT_SOMPI) {
                break;
            }
            let entries = make_entries(&selected_cells, covenant_id, funding)?;
            let within_safe_limits = |mass: &MassBreakdown| {
                mass.effective <= mass_limit && mass.storage_commitment <= storage_target
            };
            let evaluate = |covenant_total: u64| -> Result<(Transaction, MassBreakdown)> {
                let mut candidate = transaction_template.clone();
                candidate.inputs[funding_input_index].previous_outpoint = funding.outpoint;
                if covenant_output_count == 1 {
                    candidate.outputs[0].value = covenant_total;
                } else {
                    candidate.outputs[0].value = covenant_total / 2;
                    candidate.outputs[1].value = covenant_total - candidate.outputs[0].value;
                }
                candidate.outputs[funding_output_index].value = total_output_value
                    .checked_sub(covenant_total)
                    .ok_or_else(|| CoreError::InvalidRequest("KCC20 funding underflow".into()))?;
                let populated = PopulatedTransaction::new(&candidate, entries.clone());
                let candidate_mass = calculate_mass(&mass_calculator, &candidate, &populated)?;
                Ok((candidate, candidate_mass))
            };

            let (minimum_transaction, minimum_mass) = evaluate(minimum_covenant_total)?;
            let next_fee = (request.fee_rate * minimum_mass.fee as f64).ceil() as u64;
            if next_fee > required_fee {
                required_fee = next_fee;
                continue;
            }

            // For outputs with pluralities 2[, 2], 1, the harmonic storage
            // term is minimized when their values have the same ratio. Search
            // only up to that minimum and retain the smallest covenant reserve
            // which passes the conservative storage target.
            let covenant_plurality = (covenant_output_count as u128) * 2;
            let ideal_covenant_total = ((total_output_value as u128 * covenant_plurality)
                / (covenant_plurality + 1)) as u64;
            let high =
                ideal_covenant_total.min(total_output_value.saturating_sub(DUST_LIMIT_SOMPI));
            let (mut transaction, mass, locked_kas_output) = if within_safe_limits(&minimum_mass) {
                (minimum_transaction, minimum_mass, minimum_covenant_total)
            } else {
                if high <= minimum_covenant_total {
                    break;
                }
                let (high_transaction, high_mass) = evaluate(high)?;
                if !within_safe_limits(&high_mass) {
                    break;
                }
                let mut low = minimum_covenant_total;
                let mut high_value = high;
                let mut best_transaction = high_transaction;
                let mut best_mass = high_mass;
                while low + 1 < high_value {
                    let middle = low + (high_value - low) / 2;
                    let (middle_transaction, middle_mass) = evaluate(middle)?;
                    if within_safe_limits(&middle_mass) {
                        high_value = middle;
                        best_transaction = middle_transaction;
                        best_mass = middle_mass;
                    } else {
                        low = middle;
                    }
                }
                (best_transaction, best_mass, high_value)
            };
            if transaction.outputs[funding_output_index].value < DUST_LIMIT_SOMPI {
                break;
            }
            let locked_kas_top_up = locked_kas_output.saturating_sub(locked_kas_sompi);
            let locked_kas_released = locked_kas_sompi.saturating_sub(locked_kas_output);
            transaction.set_storage_mass(mass.storage_commitment);
            transaction.finalize();
            let candidate = FundedKcc20 {
                transaction,
                entries,
                mass,
                fee: required_fee,
                locked_kas_top_up,
                locked_kas_released,
                locked_kas_output,
            };
            if best
                .as_ref()
                .map(|current| {
                    (
                        candidate.locked_kas_output,
                        candidate.fee,
                        candidate.mass.effective,
                    ) < (
                        current.locked_kas_output,
                        current.fee,
                        current.mass.effective,
                    )
                })
                .unwrap_or(true)
            {
                best = Some(candidate);
            }
            break;
        }
    }
    let FundedKcc20 {
        transaction,
        entries,
        mass,
        fee,
        locked_kas_top_up,
        locked_kas_released,
        locked_kas_output,
    } = best.ok_or_else(|| {
        CoreError::Transaction(
            "no KAS funding UTXO can keep this KCC20 transfer below the Toccata mass limit".into(),
        )
    })?;

    let review_value = json!({
        "format": "kaspire-kcc20-transfer-v1",
        "network": "kaspa:mainnet",
        "version": TX_VERSION_TOCCATA,
        "sender": sender.to_string(),
        "recipient": recipient.to_string(),
        "covenantId": request.covenant_id.to_lowercase(),
        "templateHash": local_template_hash,
        "ticker": request.ticker.to_uppercase(),
        "decimals": request.decimals,
        "amount": request.amount,
        "tokenChange": token_change,
        "lockedKasSompi": locked_kas_sompi,
        "lockedKasTopUpSompi": locked_kas_top_up,
        "lockedKasReleasedSompi": locked_kas_released,
        "lockedKasOutputSompi": locked_kas_output,
        "feeSompi": fee,
        "mass": mass.effective,
        "computeMass": mass.compute,
        "storageMass": mass.storage,
        "storageMassCommitment": mass.storage_commitment,
        "storageMassTarget": storage_target,
        "transientMass": mass.transient,
        "feeMass": mass.fee,
        "feeRateSompiPerGram": request.fee_rate,
        "computeBudgets": transaction.inputs.iter().map(|input| input.compute_commit.compute_budget().map(u64::from).unwrap_or_default()).collect::<Vec<_>>(),
        "inputs": transaction.inputs.iter().map(|input| json!({
            "transactionId": input.previous_outpoint.transaction_id.to_string(),
            "index": input.previous_outpoint.index
        })).collect::<Vec<_>>(),
        "outputs": transaction.outputs.iter().map(|output| json!({
            "amountSompi": output.value,
            "script": hex::encode(output.script_public_key.script()),
            "covenantId": output.covenant.map(|binding| binding.covenant_id.to_string()),
            "authorizingInput": output.covenant.map(|binding| binding.authorizing_input),
        })).collect::<Vec<_>>(),
    });
    let review_hash = hex::encode(Sha256::digest(
        serde_json::to_vec(&review_value).map_err(|_| CoreError::Serialization)?,
    ));
    let review = PreparedKcc20Transfer {
        sender: sender.to_string(),
        recipient: recipient.to_string(),
        covenant_id: request.covenant_id.to_lowercase(),
        ticker: request.ticker.to_uppercase(),
        amount: request.amount,
        token_change,
        locked_kas_sompi,
        locked_kas_top_up_sompi: locked_kas_top_up,
        locked_kas_released_sompi: locked_kas_released,
        locked_kas_output_sompi: locked_kas_output,
        fee_sompi: fee,
        mass: mass.effective,
        compute_mass: mass.compute,
        storage_mass: mass.storage,
        storage_mass_commitment: mass.storage_commitment,
        storage_mass_target: storage_target,
        transient_mass: mass.transient,
        fee_mass: mass.fee,
        covenant_input_count: selected_cells.len(),
        covenant_output_count: if token_change == 0 { 1 } else { 2 },
        compute_budget: selected_cells.len() as u64 * u64::from(KCC20_COMPUTE_BUDGET)
            + u64::from(FEE_COMPUTE_BUDGET),
        template_hash: local_template_hash,
        review_hash,
    };
    Ok(BuiltKcc20 {
        transaction,
        entries,
        selected_cells,
        review,
    })
}

fn validate_cell(cell: &Kcc20Cell, owner: &[u8; 32], covenant_id: Hash) -> Result<()> {
    if cell.value_sompi == 0 || cell.token_amount == 0 || cell.is_minter {
        return Err(CoreError::InvalidRequest(
            "zero-value or minter KCC20 cells cannot be transferred".into(),
        ));
    }
    TransactionId::from_str(&cell.transaction_id)
        .map_err(|_| CoreError::UntrustedUtxo("invalid KCC20 transaction ID".into()))?;
    let supplied_script = hex::decode(&cell.script_public_key)
        .map_err(|_| CoreError::UntrustedUtxo("invalid KCC20 script".into()))?;
    let compiled = compile_state(owner, cell.token_amount, false)?;
    let expected = pay_to_script_hash_script(&compiled.script);
    if supplied_script.as_slice() != expected.script() {
        return Err(CoreError::UntrustedUtxo(
            "KCC20 state does not match its live output script".into(),
        ));
    }
    let cell_covenant_id = Hash::from_str(&cell.covenant_id)
        .map_err(|_| CoreError::UntrustedUtxo("invalid KCC20 cell covenant ID".into()))?;
    if cell_covenant_id != covenant_id {
        return Err(CoreError::UntrustedUtxo(
            "KCC20 cell belongs to a different covenant".into(),
        ));
    }
    Ok(())
}

fn select_cells(cells: &[Kcc20Cell], amount: u64) -> Result<Vec<Kcc20Cell>> {
    let mut best: Option<(Vec<Kcc20Cell>, (u64, usize, u64))> = None;
    for cell in cells.iter().filter(|cell| cell.token_amount >= amount) {
        consider_cell_candidate(&mut best, vec![cell.clone()], amount)?;
    }
    for (index, first) in cells.iter().enumerate() {
        for second in cells.iter().skip(index + 1) {
            let total = first
                .token_amount
                .checked_add(second.token_amount)
                .ok_or_else(|| CoreError::InvalidRequest("KCC20 amount overflow".into()))?;
            if total >= amount {
                consider_cell_candidate(&mut best, vec![first.clone(), second.clone()], amount)?;
            }
        }
    }
    best.map(|(cells, _)| cells).ok_or_else(|| {
        CoreError::InvalidRequest(
            "amount needs more than two KCC20 cells; consolidate first".into(),
        )
    })
}

fn consider_cell_candidate(
    best: &mut Option<(Vec<Kcc20Cell>, (u64, usize, u64))>,
    cells: Vec<Kcc20Cell>,
    amount: u64,
) -> Result<()> {
    let total_tokens = cells
        .iter()
        .try_fold(0u64, |sum, cell| sum.checked_add(cell.token_amount))
        .ok_or_else(|| CoreError::InvalidRequest("KCC20 amount overflow".into()))?;
    let total_value = cells
        .iter()
        .try_fold(0u64, |sum, cell| sum.checked_add(cell.value_sompi))
        .ok_or_else(|| CoreError::InvalidRequest("KCC20 cell value overflow".into()))?;
    // Cell selection must not reject token cells merely because their current
    // KAS reserve is small. The funding pass can replenish the reserve. Use a
    // dust-sized provisional reserve here only to rank otherwise valid input
    // combinations.
    let output_count = if amount == total_tokens { 1 } else { 2 };
    let provisional_total = total_value.max(DUST_LIMIT_SOMPI.saturating_mul(output_count));
    let outputs = split_cell_value(provisional_total, amount, total_tokens)?;
    let storm = MAINNET_PARAMS.storage_mass_parameter;
    // Covenant cells occupy two 100-byte storage units, so each contributes
    // C * 2² / value to KIP-0009's harmonic storage term.
    let output_harmonic = outputs.iter().try_fold(0u64, |sum, value| {
        sum.checked_add(
            storm
                .checked_mul(4)
                .and_then(|weighted| weighted.checked_div(*value))
                .ok_or_else(|| CoreError::Transaction("KCC20 storage score overflow".into()))?,
        )
        .ok_or_else(|| CoreError::Transaction("KCC20 storage score overflow".into()))
    })?;
    let input_harmonic = cells.iter().try_fold(0u64, |sum, cell| {
        sum.checked_add(
            storm
                .checked_mul(4)
                .and_then(|weighted| weighted.checked_div(cell.value_sompi))
                .ok_or_else(|| CoreError::Transaction("KCC20 storage score overflow".into()))?,
        )
        .ok_or_else(|| CoreError::Transaction("KCC20 storage score overflow".into()))
    })?;
    let normalized_storage = ((output_harmonic.saturating_sub(input_harmonic) as f64)
        * MAINNET_PARAMS
            .mempool_block_mass_cofactors()
            .after()
            .storage)
        .ceil() as u64;
    let committed_compute = cells.len() as u64 * u64::from(KCC20_COMPUTE_BUDGET) * 100;
    let score = (
        normalized_storage.max(committed_compute),
        cells.len(),
        total_tokens - amount,
    );
    if best
        .as_ref()
        .map(|(_, current)| score < *current)
        .unwrap_or(true)
    {
        *best = Some((cells, score));
    }
    Ok(())
}

fn split_cell_value(total_value: u64, amount: u64, total_tokens: u64) -> Result<Vec<u64>> {
    if amount == total_tokens {
        return Ok(vec![total_value]);
    }
    // Token quantity and locked KAS are independent covenant state. For two
    // equally-sized covenant outputs, KIP-0009's reciprocal storage term is
    // minimized by splitting the preserved KAS as evenly as possible.
    let recipient = total_value / 2;
    let change = total_value - recipient;
    if recipient < DUST_LIMIT_SOMPI || change < DUST_LIMIT_SOMPI {
        return Err(CoreError::InvalidRequest(
            "locked KAS is too small to create the KCC20 change cell".into(),
        ));
    }
    Ok(vec![recipient, change])
}

fn calculate_mass(
    calculator: &MassCalculator,
    transaction: &Transaction,
    populated: &PopulatedTransaction<'_>,
) -> Result<MassBreakdown> {
    let non_contextual = calculator.calc_non_contextual_masses(transaction);
    let contextual = calculator
        .calc_contextual_masses(populated)
        .ok_or_else(|| CoreError::Transaction("storage mass cannot be calculated".into()))?;
    let cofactors = MAINNET_PARAMS.mempool_block_mass_cofactors().after();
    let storage = (contextual.storage_mass as f64 * cofactors.storage).ceil() as u64;
    let transient = (non_contextual.transient_mass as f64 * cofactors.transient).ceil() as u64;
    let effective = Mass::new(
        non_contextual,
        ContextualMasses::new(contextual.storage_mass),
    )
    .normalized_max(&cofactors);
    Ok(MassBreakdown {
        effective,
        compute: non_contextual.compute_mass,
        storage,
        storage_commitment: contextual.storage_mass,
        transient,
        fee: non_contextual.compute_mass.max(transient),
    })
}

#[allow(clippy::too_many_arguments)]
fn make_transaction(
    cells: &[Kcc20Cell],
    sender: &Address,
    recipient_owner: &[u8; 32],
    sender_owner: &[u8; 32],
    amount: u64,
    token_change: u64,
    cell_values: &[u64],
    covenant_id: Hash,
    funding: &Spendable,
    funding_change: u64,
) -> Result<Transaction> {
    let mut inputs = Vec::with_capacity(cells.len() + 1);
    for cell in cells {
        inputs.push(TransactionInput::new_with_mass(
            TransactionOutpoint::new(
                TransactionId::from_str(&cell.transaction_id)
                    .map_err(|_| CoreError::UntrustedUtxo("invalid KCC20 transaction ID".into()))?,
                cell.index,
            ),
            vec![],
            0,
            ComputeCommit::ComputeBudget(ComputeBudget(KCC20_COMPUTE_BUDGET)),
        ));
    }
    inputs.push(TransactionInput::new_with_mass(
        funding.outpoint,
        vec![],
        0,
        ComputeCommit::ComputeBudget(ComputeBudget(FEE_COMPUTE_BUDGET)),
    ));

    let recipient_contract = compile_state(recipient_owner, amount, false)?;
    let mut outputs = vec![TransactionOutput::with_covenant(
        cell_values[0],
        pay_to_script_hash_script(&recipient_contract.script),
        Some(CovenantBinding::new(0, covenant_id)),
    )];
    if token_change > 0 {
        let change_contract = compile_state(sender_owner, token_change, false)?;
        outputs.push(TransactionOutput::with_covenant(
            cell_values[1],
            pay_to_script_hash_script(&change_contract.script),
            Some(CovenantBinding::new(0, covenant_id)),
        ));
    }
    if funding_change >= DUST_LIMIT_SOMPI {
        outputs.push(TransactionOutput::new(
            funding_change,
            pay_to_address_script(sender),
        ));
    }
    Ok(Transaction::new(
        TX_VERSION_TOCCATA,
        inputs,
        outputs,
        0,
        SUBNETWORK_ID_NATIVE,
        0,
        vec![],
    ))
}

fn add_dummy_scripts(
    transaction: &mut Transaction,
    cells: &[Kcc20Cell],
    sender_owner: &[u8; 32],
    recipient_owner: &[u8; 32],
    amount: u64,
    token_change: u64,
) -> Result<()> {
    let signatures = vec![vec![0; SIGNATURE_WITH_HASH_TYPE_LEN]; cells.len()];
    let states = state_array(
        recipient_owner,
        amount,
        (token_change > 0).then_some((sender_owner, token_change)),
    )?;
    for (index, cell) in cells.iter().enumerate() {
        let compiled = compile_state(sender_owner, cell.token_amount, false)?;
        transaction.inputs[index].signature_script = covenant_sigscript(
            &compiled,
            if index == 0 {
                vec![
                    states.clone(),
                    signature_array(&signatures),
                    Expr::bytes((0..cells.len() as u8).collect()),
                ]
            } else {
                vec![]
            },
            index == 0,
        )?;
    }
    transaction.inputs[cells.len()].signature_script = ScriptBuilder::new()
        .add_data(&vec![0; SIGNATURE_WITH_HASH_TYPE_LEN])
        .map_err(|error| CoreError::Transaction(error.to_string()))?
        .drain();
    Ok(())
}

fn make_entries(
    cells: &[Kcc20Cell],
    covenant_id: Hash,
    funding: &Spendable,
) -> Result<Vec<UtxoEntry>> {
    let mut entries = Vec::with_capacity(cells.len() + 1);
    for cell in cells {
        let script = hex::decode(&cell.script_public_key)
            .map_err(|_| CoreError::UntrustedUtxo("invalid KCC20 script".into()))?;
        entries.push(UtxoEntry::new(
            cell.value_sompi,
            kaspa_consensus_core::tx::ScriptPublicKey::new(0, script.into()),
            cell.block_daa_score,
            false,
            Some(covenant_id),
        ));
    }
    entries.push(funding.entry.clone());
    Ok(entries)
}

fn compile_state(
    owner: &[u8; 32],
    amount: u64,
    is_minter: bool,
) -> Result<CompiledContract<'static>> {
    let amount = i64::try_from(amount).map_err(|_| {
        CoreError::InvalidRequest("KCC20 amount exceeds signed 64-bit range".into())
    })?;
    compile_contract(
        KCC20_SOURCE,
        &[
            Expr::bytes(owner.to_vec()),
            Expr::int(amount),
            Expr::byte(0),
            Expr::bool(is_minter),
            Expr::int(KCC20_MAX_INPUTS as i64),
            Expr::int(KCC20_MAX_OUTPUTS as i64),
        ],
        CompileOptions::default(),
    )
    .map_err(|error| CoreError::Transaction(format!("KCC20 compile failed: {error}")))
}

fn state_array(
    recipient_owner: &[u8; 32],
    amount: u64,
    change: Option<(&[u8; 32], u64)>,
) -> Result<Expr<'static>> {
    let mut values = vec![state(recipient_owner, amount)?];
    if let Some((owner, amount)) = change {
        values.push(state(owner, amount)?);
    }
    Ok(values.into())
}

fn state(owner: &[u8; 32], amount: u64) -> Result<Expr<'static>> {
    let amount = i64::try_from(amount).map_err(|_| {
        CoreError::InvalidRequest("KCC20 amount exceeds signed 64-bit range".into())
    })?;
    Ok(struct_object(vec![
        ("ownerIdentifier", Expr::bytes(owner.to_vec())),
        ("identifierType", Expr::byte(0)),
        ("amount", Expr::int(amount)),
        ("isMinter", Expr::bool(false)),
    ]))
}

fn signature_array(signatures: &[Vec<u8>]) -> Expr<'static> {
    signatures
        .iter()
        .cloned()
        .map(Expr::bytes)
        .collect::<Vec<_>>()
        .into()
}

fn covenant_sigscript(
    compiled: &CompiledContract<'_>,
    args: Vec<Expr<'_>>,
    is_leader: bool,
) -> Result<Vec<u8>> {
    let mut script = compiled
        .build_sig_script_for_covenant_decl("transfer", args, CovenantDeclCallOptions { is_leader })
        .map_err(|error| CoreError::Transaction(format!("KCC20 witness failed: {error}")))?;
    let redeem = ScriptBuilder::with_flags(EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    })
    .add_data(&compiled.script)
    .map_err(|error| CoreError::Transaction(error.to_string()))?
    .drain();
    script.extend_from_slice(&redeem);
    Ok(script)
}

fn address_pubkey(address: &Address) -> Result<[u8; 32]> {
    if address.version != AddressVersion::PubKey || address.payload.len() != 32 {
        return Err(CoreError::InvalidRequest(
            "KCC20 transfers currently require a P2PK sender and recipient".into(),
        ));
    }
    address
        .payload
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidAddress)
}

fn sign_hash(
    keypair: &Keypair,
    transaction: &PopulatedTransaction<'_>,
    input_index: usize,
    reused: &SigHashReusedValuesUnsync,
) -> Result<Vec<u8>> {
    let hash = calc_schnorr_signature_hash(transaction, input_index, SIG_HASH_ALL, reused);
    let message = Message::from_digest_slice(hash.as_bytes().as_slice())
        .map_err(|error| CoreError::Transaction(error.to_string()))?;
    let mut signature = keypair.sign_schnorr(message).as_ref().to_vec();
    signature.push(SIG_HASH_ALL.to_u8());
    Ok(signature)
}

fn simulate_all(transaction: &Transaction, entries: &[UtxoEntry]) -> Result<()> {
    let populated = PopulatedTransaction::new(transaction, entries.to_vec());
    let covenant_context = CovenantsContext::from_tx(&populated)
        .map_err(|error| CoreError::Transaction(format!("covenant context failed: {error}")))?;
    let reused = SigHashReusedValuesUnsync::new();
    let cache = Cache::new(10_000);
    for (index, input) in transaction.inputs.iter().enumerate() {
        let utxo = populated
            .utxo(index)
            .ok_or_else(|| CoreError::Transaction("missing simulation UTXO".into()))?;
        let mut engine = TxScriptEngine::from_transaction_input_with_script_units_limit(
            &populated,
            input,
            index,
            utxo,
            EngineCtx::new(&cache)
                .with_reused(&reused)
                .with_covenants_ctx(&covenant_context),
            EngineFlags {
                covenants_enabled: true,
                sigop_script_units: Gram(MAINNET_PARAMS.mass_per_sig_op).into(),
            },
            input.compute_commit.allowed_script_units(),
        );
        engine.execute().map_err(|error| {
            CoreError::Transaction(format!(
                "local KCC20 simulation failed at input {index}: {error}"
            ))
        })?;
    }
    Ok(())
}

fn submit_json_v1(transaction: &Transaction) -> Result<String> {
    let value = transaction_json(transaction, false);
    serde_json::to_string(&json!({"transaction": value, "allowOrphan": false}))
        .map_err(|_| CoreError::Serialization)
}

fn encoded_script_public_key(version: u16, script: &[u8]) -> String {
    let mut encoded = Vec::with_capacity(2 + script.len());
    encoded.extend_from_slice(&version.to_le_bytes());
    encoded.extend_from_slice(script);
    hex::encode(encoded)
}

/// Serializes the signed transaction using the Kaspa SDK's SafeJSON schema.
/// Unlike the legacy REST submit schema, this preserves Toccata's per-input
/// `computeBudget` all the way to wRPC.
fn wrpc_safe_json(transaction: &Transaction, entries: &[UtxoEntry]) -> Result<String> {
    if transaction.inputs.len() != entries.len() {
        return Err(CoreError::Serialization);
    }
    let value = json!({
        "id": transaction.id().to_string(),
        "version": transaction.version,
        "inputs": transaction.inputs.iter().zip(entries).map(|(input, entry)| json!({
            "transactionId": input.previous_outpoint.transaction_id.to_string(),
            "index": input.previous_outpoint.index,
            "sequence": input.sequence.to_string(),
            "sigOpCount": input.compute_commit.sig_op_count().unwrap_or_default(),
            "computeBudget": input.compute_commit.compute_budget().unwrap_or_default(),
            "signatureScript": hex::encode(&input.signature_script),
            "utxo": {
                "address": Value::Null,
                "amount": entry.amount.to_string(),
                "scriptPublicKey": encoded_script_public_key(
                    entry.script_public_key.version(),
                    entry.script_public_key.script(),
                ),
                "blockDaaScore": entry.block_daa_score.to_string(),
                "isCoinbase": entry.is_coinbase,
                "covenantId": entry.covenant_id.map(|id| id.to_string()),
            },
        })).collect::<Vec<_>>(),
        "outputs": transaction.outputs.iter().map(|output| json!({
            "value": output.value.to_string(),
            "scriptPublicKey": encoded_script_public_key(
                output.script_public_key.version(),
                output.script_public_key.script(),
            ),
            "covenant": output.covenant.map(|binding| json!({
                "authorizingInput": binding.authorizing_input,
                "covenantId": binding.covenant_id.to_string(),
            })),
        })).collect::<Vec<_>>(),
        "subnetworkId": transaction.subnetwork_id.to_string(),
        "lockTime": transaction.lock_time.to_string(),
        "gas": transaction.gas.to_string(),
        "storageMass": transaction.storage_mass().to_string(),
        "payload": hex::encode(&transaction.payload),
    });
    serde_json::to_string(&value).map_err(|_| CoreError::Serialization)
}

fn preflight_json(transaction: &Transaction, entries: &[UtxoEntry]) -> Result<String> {
    let mut value = transaction_json(transaction, true);
    let inputs = value
        .get_mut("inputs")
        .and_then(Value::as_array_mut)
        .ok_or(CoreError::Serialization)?;
    for (input, entry) in inputs.iter_mut().zip(entries) {
        input
            .as_object_mut()
            .ok_or(CoreError::Serialization)?
            .insert(
                "utxo".into(),
                json!({
                    "amount": entry.amount,
                    "scriptPublicKey": {
                        "version": entry.script_public_key.version(),
                        "script": hex::encode(entry.script_public_key.script())
                    },
                    "blockDaaScore": entry.block_daa_score,
                    "isCoinbase": entry.is_coinbase,
                    "covenantId": entry.covenant_id.map(|id| id.to_string()),
                }),
            );
    }
    serde_json::to_string(&value).map_err(|_| CoreError::Serialization)
}

fn transaction_json(transaction: &Transaction, kascov: bool) -> Value {
    json!({
        "version": transaction.version,
        "inputs": transaction.inputs.iter().map(|input| json!({
            "previousOutpoint": {
                "transactionId": input.previous_outpoint.transaction_id.to_string(),
                "index": input.previous_outpoint.index
            },
            "signatureScript": hex::encode(&input.signature_script),
            "sequence": input.sequence,
            "sigOpCount": input.compute_commit.sig_op_count().unwrap_or_default(),
            "computeBudget": input.compute_commit.compute_budget().map(u64::from),
        })).collect::<Vec<_>>(),
        "outputs": transaction.outputs.iter().map(|output| {
            let script_key = if kascov { "script" } else { "scriptPublicKey" };
            let mut script = serde_json::Map::new();
            script.insert("version".into(), json!(output.script_public_key.version()));
            script.insert(script_key.into(), json!(hex::encode(output.script_public_key.script())));
            let mut value = serde_json::Map::new();
            value.insert(
                if kascov { "value" } else { "amount" }.into(),
                json!(output.value),
            );
            value.insert("scriptPublicKey".into(), json!(script));
            value.insert(
                "covenant".into(),
                json!(output.covenant.map(|binding| json!({
                    "authorizingInput": binding.authorizing_input,
                    "covenantId": binding.covenant_id.to_string(),
                }))),
            );
            Value::Object(value)
        }).collect::<Vec<_>>(),
        "lockTime": transaction.lock_time,
        "subnetworkId": transaction.subnetwork_id.to_string(),
        "gas": transaction.gas,
        "payload": hex::encode(&transaction.payload),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_request(amount: u64, token_amount: u64, value_sompi: u64) -> Kcc20TransferRequest {
        let secret = "private:0000000000000000000000000000000000000000000000000000000000000001";
        let sender = derive_address(secret).unwrap();
        let owner = address_pubkey(&sender).unwrap();
        let cell_contract = compile_state(&owner, token_amount, false).unwrap();
        let funding_script = pay_to_address_script(&sender);
        Kcc20TransferRequest {
            sender: sender.to_string(),
            recipient: sender.to_string(),
            covenant_id:
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
            ticker: "TEST".into(),
            amount,
            decimals: 0,
            fee_rate: 100.0,
            template_hash: kcc20_template_hash().unwrap(),
            cells: vec![Kcc20Cell {
                covenant_id:
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        .into(),
                transaction_id:
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                        .into(),
                index: 0,
                value_sompi,
                block_daa_score: 1,
                script_public_key: hex::encode(
                    pay_to_script_hash_script(&cell_contract.script).script(),
                ),
                token_amount,
                is_minter: false,
            }],
            funding_utxos_json: json!([{
                "address": sender.to_string(),
                "outpoint": {
                    "transactionId": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                    "index": 0
                },
                "utxoEntry": {
                    "amount": "1000000000",
                    "blockDaaScore": "1",
                    "isCoinbase": false,
                    "scriptPublicKey": {
                        "scriptPublicKey": hex::encode(funding_script.script())
                    }
                }
            }])
            .to_string(),
        }
    }

    fn replace_funding(request: &mut Kcc20TransferRequest, amounts: &[u64]) {
        let sender = Address::try_from(request.sender.as_str()).unwrap();
        let funding_script = pay_to_address_script(&sender);
        request.funding_utxos_json = Value::Array(
            amounts
                .iter()
                .enumerate()
                .map(|(index, amount)| {
                    json!({
                        "address": sender.to_string(),
                        "outpoint": {
                            "transactionId": format!("{:064x}", index + 3),
                            "index": 0
                        },
                        "utxoEntry": {
                            "amount": amount.to_string(),
                            "blockDaaScore": "1",
                            "isCoinbase": false,
                            "scriptPublicKey": {
                                "scriptPublicKey": hex::encode(funding_script.script())
                            }
                        }
                    })
                })
                .collect(),
        )
        .to_string();
    }

    #[test]
    fn audited_kcc20_template_hash_is_stable() {
        assert_eq!(
            kcc20_template_hash().unwrap(),
            "36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f"
        );
    }

    #[test]
    fn partial_transfer_balances_locked_kas_instead_of_token_ratio() {
        assert_eq!(
            split_cell_value(50_000_000, 500, 11_000).unwrap(),
            vec![25_000_000, 25_000_000]
        );
        assert_eq!(
            split_cell_value(50_000_001, 10_000, 11_000).unwrap(),
            vec![25_000_000, 25_000_001]
        );
        assert_eq!(
            split_cell_value(50_000_000, 11_000, 11_000).unwrap(),
            vec![50_000_000]
        );
    }

    #[test]
    fn partial_transfer_uses_a_token_independent_minimum_reserve() {
        let small = prepare_kcc20_transfer(&test_request(500, 11_000, 50_000_000)).unwrap();
        let middle = prepare_kcc20_transfer(&test_request(5_000, 11_000, 50_000_000)).unwrap();
        let near_all = prepare_kcc20_transfer(&test_request(10_000, 11_000, 50_000_000)).unwrap();
        let all = prepare_kcc20_transfer(&test_request(11_000, 11_000, 50_000_000)).unwrap();

        assert_eq!(small.storage_mass, middle.storage_mass);
        assert_eq!(middle.storage_mass, near_all.storage_mass);
        assert!(small.mass < 1_000_000, "unexpected mass: {}", small.mass);
        assert_eq!(
            small.mass,
            small
                .compute_mass
                .max(small.storage_mass)
                .max(small.transient_mass)
        );
        assert_eq!(small.fee_sompi, small.fee_mass * 100);
        assert_eq!(
            small.locked_kas_sompi + small.locked_kas_top_up_sompi,
            small.locked_kas_output_sompi + small.locked_kas_released_sompi
        );
        assert_eq!(
            small.locked_kas_output_sompi,
            middle.locked_kas_output_sompi
        );
        assert_eq!(
            middle.locked_kas_output_sompi,
            near_all.locked_kas_output_sompi
        );
        assert_eq!(all.covenant_output_count, 1);
    }

    #[test]
    fn funding_selection_avoids_tiny_change_and_toccata_mass_failure() {
        let mut request = test_request(500, 11_000, 50_000_000);
        replace_funding(&mut request, &[1_000_000, 27_000_000, 1_000_000_000]);
        let built = build(&request).unwrap();
        let limit = MAINNET_PARAMS
            .mempool_block_mass_limits()
            .after()
            .reference();

        assert!(built.review.mass <= limit);
        assert!(built.review.storage_mass <= limit);
        assert!(built.review.fee_sompi < 1_000_000);
        assert!(
            built.transaction.outputs.last().unwrap().value >= DUST_LIMIT_SOMPI,
            "funding change must remain spendable"
        );
    }

    #[test]
    fn minimally_tops_up_a_fragmented_token_cell_below_the_mass_limit() {
        let request = test_request(500, 11_000, 26_190_477);
        let built = build(&request).unwrap();
        let limit = MAINNET_PARAMS
            .mempool_block_mass_limits()
            .after()
            .reference();
        let total_outputs = built
            .transaction
            .outputs
            .iter()
            .map(|output| output.value)
            .sum::<u64>();

        assert!(built.review.locked_kas_top_up_sompi > 0);
        assert_eq!(
            built.review.locked_kas_output_sompi,
            built.review.locked_kas_sompi + built.review.locked_kas_top_up_sompi
        );
        assert!(built.review.mass <= limit);
        assert!(built.review.storage_mass_commitment <= limit * STORAGE_LIMIT_SAFETY_PERCENT / 100);
        assert!(built.review.storage_mass_commitment * 106 / 100 < limit);
        assert_eq!(
            total_outputs + built.review.fee_sompi,
            26_190_477 + 1_000_000_000
        );

        let secret = "private:0000000000000000000000000000000000000000000000000000000000000001";
        let signed = sign_kcc20_transfer(secret, &request, &built.review.review_hash).unwrap();
        assert!(!signed.transaction_id.is_empty());
    }

    #[test]
    fn excess_token_cell_kas_returns_as_standard_wallet_change() {
        let request = test_request(500, 11_000, 1_000_000_000);
        let built = build(&request).unwrap();
        let total_outputs = built
            .transaction
            .outputs
            .iter()
            .map(|output| output.value)
            .sum::<u64>();

        assert!(built.review.locked_kas_released_sompi > 0);
        assert_eq!(built.review.locked_kas_top_up_sompi, 0);
        assert!(built.review.locked_kas_output_sompi < built.review.locked_kas_sompi);
        assert_eq!(
            built.review.locked_kas_sompi,
            built.review.locked_kas_output_sompi + built.review.locked_kas_released_sompi
        );
        assert_eq!(
            total_outputs + built.review.fee_sompi,
            1_000_000_000 + 1_000_000_000
        );
    }

    #[test]
    fn repeated_partial_transfer_keeps_the_sender_change_cell_mass_safe() {
        let mut request = test_request(500, 11_000, 50_000_000);
        let limit = MAINNET_PARAMS.mempool_block_mass_limits().after().storage;

        for daa_score in 2..10 {
            let built = build(&request).unwrap();
            assert!(built.review.storage_mass_commitment <= limit * 85 / 100);
            assert_eq!(
                built.review.locked_kas_sompi + built.review.locked_kas_top_up_sompi,
                built.review.locked_kas_output_sompi + built.review.locked_kas_released_sompi
            );

            let sender_change = &built.transaction.outputs[1];
            assert!(
                sender_change.value >= DUST_LIMIT_SOMPI,
                "the next sender token cell must retain a spendable reserve"
            );
            let normal_change = built.transaction.outputs.last().unwrap().value;
            request.cells = vec![Kcc20Cell {
                covenant_id: request.covenant_id.clone(),
                transaction_id: built.transaction.id().to_string(),
                index: 1,
                value_sompi: sender_change.value,
                block_daa_score: daa_score,
                script_public_key: hex::encode(sender_change.script_public_key.script()),
                token_amount: built.review.token_change,
                is_minter: false,
            }];
            replace_funding(&mut request, &[normal_change]);
        }
    }

    #[test]
    fn selection_can_consolidate_when_it_lowers_storage_mass() {
        let cells = vec![
            Kcc20Cell {
                covenant_id:
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        .into(),
                transaction_id: "1111111111111111111111111111111111111111111111111111111111111111"
                    .into(),
                index: 0,
                value_sompi: 10_000_000,
                block_daa_score: 1,
                script_public_key: "00".into(),
                token_amount: 1_000,
                is_minter: false,
            },
            Kcc20Cell {
                covenant_id:
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        .into(),
                transaction_id: "2222222222222222222222222222222222222222222222222222222222222222"
                    .into(),
                index: 0,
                value_sompi: 50_000_000,
                block_daa_score: 1,
                script_public_key: "00".into(),
                token_amount: 2_000,
                is_minter: false,
            },
        ];
        let selected = select_cells(&cells, 500).unwrap();
        assert_eq!(selected.len(), 2);
        assert!(selected.iter().any(|cell| {
            cell.transaction_id
                == "2222222222222222222222222222222222222222222222222222222222222222"
        }));
    }

    #[test]
    fn rejects_duplicate_cell_outpoints_before_selection() {
        let secret =
            "private:0000000000000000000000000000000000000000000000000000000000000001";
        let sender = derive_address(secret).unwrap().to_string();
        let covenant_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let cell = Kcc20Cell {
            covenant_id: covenant_id.into(),
            transaction_id:
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .into(),
            index: 0,
            value_sompi: 50_000_000,
            block_daa_score: 1,
            script_public_key: "00".into(),
            token_amount: 1_000,
            is_minter: false,
        };
        let request = Kcc20TransferRequest {
            sender: sender.clone(),
            recipient: sender,
            covenant_id: covenant_id.into(),
            ticker: "TEST".into(),
            amount: 400,
            decimals: 0,
            fee_rate: 100.0,
            template_hash: kcc20_template_hash().unwrap(),
            cells: vec![cell.clone(), cell],
            funding_utxos_json: "[]".into(),
        };

        let error = match build(&request) {
            Err(error) => error,
            Ok(_) => panic!("duplicate outpoints must be rejected"),
        };
        assert!(error.to_string().contains("duplicate KCC20 cell outpoint"));
    }

    #[test]
    fn signs_and_simulates_a_typed_transfer() {
        let secret = "private:0000000000000000000000000000000000000000000000000000000000000001";
        let sender = derive_address(secret).unwrap();
        let owner = address_pubkey(&sender).unwrap();
        let cell_contract = compile_state(&owner, 1_000, false).unwrap();
        let funding_script = pay_to_address_script(&sender);
        let covenant_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let request = Kcc20TransferRequest {
            sender: sender.to_string(),
            recipient: sender.to_string(),
            covenant_id: covenant_id.into(),
            ticker: "TEST".into(),
            amount: 400,
            decimals: 0,
            fee_rate: 100.0,
            template_hash: kcc20_template_hash().unwrap(),
            cells: vec![Kcc20Cell {
                covenant_id: covenant_id.into(),
                transaction_id:
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                        .into(),
                index: 0,
                value_sompi: 50_000_000,
                block_daa_score: 1,
                script_public_key: hex::encode(
                    pay_to_script_hash_script(&cell_contract.script).script(),
                ),
                token_amount: 1_000,
                is_minter: false,
            }],
            funding_utxos_json: json!([{
                "address": sender.to_string(),
                "outpoint": {
                    "transactionId": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                    "index": 0
                },
                "utxoEntry": {
                    "amount": "1000000000",
                    "blockDaaScore": "1",
                    "isCoinbase": false,
                    "scriptPublicKey": {
                        "scriptPublicKey": hex::encode(funding_script.script())
                    }
                }
            }])
            .to_string(),
        };
        let prepared = prepare_kcc20_transfer(&request).unwrap();
        let signed = sign_kcc20_transfer(secret, &request, &prepared.review_hash).unwrap();
        assert_eq!(signed.review_hash, prepared.review_hash);
        assert!(!signed.transaction_id.is_empty());
        assert!(signed.submit_json.contains("\"version\":1"));
        assert!(signed
            .preflight_json
            .contains(&format!("\"computeBudget\":{KCC20_COMPUTE_BUDGET}")));
        let wrpc: Value = serde_json::from_str(&signed.wrpc_json).unwrap();
        assert_eq!(wrpc["id"], signed.transaction_id);
        assert_eq!(wrpc["version"], TX_VERSION_TOCCATA);
        assert_eq!(wrpc["inputs"][0]["computeBudget"], KCC20_COMPUTE_BUDGET);
        assert_eq!(wrpc["inputs"][1]["computeBudget"], FEE_COMPUTE_BUDGET);
        assert_eq!(wrpc["inputs"][0]["sigOpCount"], 0);
        assert_eq!(
            wrpc["outputs"][0]["covenant"]["covenantId"],
            request.covenant_id
        );
        assert_eq!(wrpc["storageMass"], signed.storage_mass.to_string());
    }

    #[test]
    fn rejects_a_cell_attributed_to_another_covenant() {
        let mut request = test_request(400, 1_000, 50_000_000);
        request.cells[0].covenant_id =
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd".into();
        let error = prepare_kcc20_transfer(&request).unwrap_err();
        assert!(error.to_string().contains("different covenant"));
    }

    #[test]
    fn signs_and_simulates_a_two_cell_transfer() {
        let secret = "private:0000000000000000000000000000000000000000000000000000000000000001";
        let mut request = test_request(500, 1_000, 10_000_000);
        let sender = Address::try_from(request.sender.as_str()).unwrap();
        let owner = address_pubkey(&sender).unwrap();
        let second_contract = compile_state(&owner, 2_000, false).unwrap();
        request.cells.push(Kcc20Cell {
            covenant_id: request.covenant_id.clone(),
            transaction_id: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
                .into(),
            index: 0,
            value_sompi: 50_000_000,
            block_daa_score: 1,
            script_public_key: hex::encode(
                pay_to_script_hash_script(&second_contract.script).script(),
            ),
            token_amount: 2_000,
            is_minter: false,
        });

        let prepared = prepare_kcc20_transfer(&request).unwrap();
        assert_eq!(prepared.covenant_input_count, 2);
        sign_kcc20_transfer(secret, &request, &prepared.review_hash).unwrap();
    }
}
