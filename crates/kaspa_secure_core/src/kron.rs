use crate::transaction::parse_utxos;
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Version as AddressVersion};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    constants::TX_VERSION_TOCCATA,
    mass::MassCalculator,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, CovenantBinding, PopulatedTransaction, Transaction, TransactionInput,
        TransactionOutpoint, TransactionOutput, UtxoEntry,
    },
    Hash,
};
use kaspa_txscript::{
    pay_to_address_script, pay_to_script_hash_script, script_builder::ScriptBuilder, EngineFlags,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{collections::HashSet, str::FromStr};

const TOKEN_COMPUTE_BUDGET: u16 = 100;
const FUNDING_COMPUTE_BUDGET: u16 = 10;
const TOKEN_CELL_VALUE: u64 = 50_000_000;
const MIN_FEE: u64 = 10_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct KronCell {
    pub transaction_id: String,
    pub index: u32,
    pub value_sompi: u64,
    pub block_daa_score: u64,
    pub script_public_key: String,
    pub token_amount: u64,
    pub redeem_script: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct KronTransferRequest {
    pub sender: String,
    pub recipient: String,
    pub covenant_id: String,
    pub ticker: String,
    pub amount: u64,
    pub decimals: u8,
    pub fee_rate: f64,
    pub template_hash: String,
    pub cells: Vec<KronCell>,
    pub funding_utxos_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedKronTransfer {
    pub pskt_request: crate::PsktRequest,
    pub transaction_id: String,
    pub fee_sompi: u64,
    pub input_total_sompi: u64,
    pub output_total_sompi: u64,
    pub token_change: u64,
    pub locked_kas_sompi: u64,
    pub locked_kas_top_up_sompi: u64,
    pub locked_kas_released_sompi: u64,
    pub locked_kas_output_sompi: u64,
    pub covenant_input_count: usize,
    pub covenant_output_count: usize,
    pub compute_budget: u64,
    pub compute_mass: u64,
    pub transient_mass: u64,
    pub fee_mass: u64,
    pub template_hash: String,
    pub raw_json: serde_json::Value,
}

struct State {
    template: Vec<u8>,
    state_start: usize,
    owner: [u8; 32],
    amount: u64,
}

pub fn prepare_kron_transfer(request: &KronTransferRequest) -> Result<PreparedKronTransfer> {
    if request.amount == 0
        || request.cells.is_empty()
        || request.cells.len() > 4
        || !request.fee_rate.is_finite()
        || !(1.0..=10_000.0).contains(&request.fee_rate)
    {
        return Err(CoreError::InvalidRequest(
            "invalid KRON transfer request".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let recipient =
        Address::try_from(request.recipient.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let sender_owner = address_owner(&sender)?;
    let recipient_owner = address_owner(&recipient)?;
    let covenant_id = Hash::from_str(&request.covenant_id)
        .map_err(|_| CoreError::InvalidRequest("invalid KRON covenant id".into()))?;
    let mut seen = HashSet::new();
    let mut decoded = Vec::with_capacity(request.cells.len());
    let mut token_total = 0u64;
    let mut locked_in = 0u64;
    for cell in &request.cells {
        if !seen.insert((cell.transaction_id.clone(), cell.index)) {
            return Err(CoreError::InvalidRequest(
                "duplicate KRON cell outpoint".into(),
            ));
        }
        let redeem = hex::decode(&cell.redeem_script)
            .map_err(|_| CoreError::UntrustedUtxo("invalid KRON redeem script".into()))?;
        let state = decode_state(redeem)?;
        if state.owner != sender_owner || state.amount != cell.token_amount {
            return Err(CoreError::UntrustedUtxo(
                "KRON owner or amount mismatch".into(),
            ));
        }
        let expected = pay_to_script_hash_script(&state.template);
        if hex::encode(expected.script()) != normalize_script_public_key(&cell.script_public_key) {
            return Err(CoreError::UntrustedUtxo(
                "KRON redeem script does not match live output".into(),
            ));
        }
        token_total = token_total
            .checked_add(cell.token_amount)
            .ok_or_else(|| CoreError::InvalidRequest("KRON token amount overflow".into()))?;
        locked_in = locked_in
            .checked_add(cell.value_sompi)
            .ok_or_else(|| CoreError::InvalidRequest("KRON cell value overflow".into()))?;
        decoded.push(state);
    }
    if token_total < request.amount {
        return Err(CoreError::InvalidRequest(
            "insufficient KRON token balance".into(),
        ));
    }
    for state in decoded.iter().skip(1) {
        if !same_template(&decoded[0], state) {
            return Err(CoreError::UntrustedUtxo(
                "KRON cells use different templates".into(),
            ));
        }
    }
    let token_change = token_total - request.amount;
    let output_count = if token_change > 0 { 2 } else { 1 };
    let locked_out = TOKEN_CELL_VALUE * output_count as u64;
    let outputs_state = if token_change > 0 {
        vec![
            (recipient_owner, request.amount),
            (sender_owner, token_change),
        ]
    } else {
        vec![(recipient_owner, request.amount)]
    };
    let witnesses = vec![request.cells.len() as u8; request.cells.len()];
    let mut covenant_inputs = Vec::new();
    let mut entries = Vec::new();
    for (cell, state) in request.cells.iter().zip(&decoded) {
        covenant_inputs.push(TransactionInput::new_with_mass(
            TransactionOutpoint::new(
                cell.transaction_id
                    .parse()
                    .map_err(|_| CoreError::UntrustedUtxo("invalid KRON transaction id".into()))?,
                cell.index,
            ),
            transfer_sig_script(&state.template, &outputs_state, &witnesses)?,
            0,
            ComputeCommit::ComputeBudget(TOKEN_COMPUTE_BUDGET.into()),
        ));
        entries.push(UtxoEntry::new(
            cell.value_sompi,
            pay_to_script_hash_script(&state.template),
            cell.block_daa_score,
            false,
            Some(covenant_id),
        ));
    }
    let mut funding = parse_utxos(&request.funding_utxos_json, &sender)?;
    funding.sort_by_key(|item| std::cmp::Reverse(item.entry.amount));
    let funding = funding
        .into_iter()
        .next()
        .ok_or(CoreError::InsufficientFunds)?;
    let input_total = locked_in
        .checked_add(funding.entry.amount)
        .ok_or(CoreError::Serialization)?;
    let mut fee = MIN_FEE;
    let mut transaction;
    let mut mass = (0, 0, 0, 0);
    for _ in 0..3 {
        transaction = make_transaction(
            covenant_inputs.clone(),
            &outputs_state,
            &decoded[0],
            covenant_id,
            &funding,
            &sender,
            input_total,
            locked_out,
            fee,
            0,
        )?;
        let mut estimate = transaction.clone();
        estimate.inputs[request.cells.len()].signature_script = vec![0; 66];
        let mut estimate_entries = entries.clone();
        estimate_entries.push(funding.entry.clone());
        let calculator = MassCalculator::new(
            MAINNET_PARAMS.mass_per_tx_byte,
            MAINNET_PARAMS.mass_per_script_pub_key_byte,
            MAINNET_PARAMS.storage_mass_parameter,
        );
        let non = calculator.calc_non_contextual_masses(&estimate);
        let populated = PopulatedTransaction::new(&estimate, estimate_entries);
        let contextual = calculator
            .calc_contextual_masses(&populated)
            .ok_or_else(|| CoreError::Transaction("KRON storage mass unavailable".into()))?;
        let cofactors = MAINNET_PARAMS.mempool_block_mass_cofactors().after();
        let transient = (non.transient_mass as f64 * cofactors.transient).ceil() as u64;
        let compute = non.compute_mass;
        let fee_mass = compute.max(transient);
        let next_fee =
            ((fee_mass as f64 * request.fee_rate.max(100.0) * 1.2).ceil() as u64).max(MIN_FEE);
        mass = (compute, transient, fee_mass, contextual.storage_mass);
        if next_fee == fee {
            break;
        }
        fee = next_fee;
    }
    transaction = make_transaction(
        covenant_inputs,
        &outputs_state,
        &decoded[0],
        covenant_id,
        &funding,
        &sender,
        input_total,
        locked_out,
        fee,
        mass.3,
    )?;
    let mut all_entries = entries;
    all_entries.push(funding.entry.clone());
    let raw = safe_json(&transaction, &all_entries);
    let pskt_request = crate::PsktRequest {
        sender: request.sender.clone(),
        tx_json_string: raw.to_string(),
        sign_inputs: vec![crate::PsktSignInput {
            index: request.cells.len(),
            sighash_type: 1,
        }],
        scripts: vec![],
    };
    let reviewed = crate::prepare_pskt(&pskt_request)?;
    Ok(PreparedKronTransfer {
        pskt_request,
        transaction_id: reviewed.transaction_id,
        fee_sompi: reviewed.fee_sompi,
        input_total_sompi: reviewed.input_total_sompi,
        output_total_sompi: reviewed.output_total_sompi,
        token_change,
        locked_kas_sompi: locked_in,
        locked_kas_top_up_sompi: locked_out.saturating_sub(locked_in),
        locked_kas_released_sompi: locked_in.saturating_sub(locked_out),
        locked_kas_output_sompi: locked_out,
        covenant_input_count: request.cells.len(),
        covenant_output_count: output_count,
        compute_budget: request.cells.len() as u64 * TOKEN_COMPUTE_BUDGET as u64
            + FUNDING_COMPUTE_BUDGET as u64,
        compute_mass: mass.0,
        transient_mass: mass.1,
        fee_mass: mass.2,
        template_hash: request.template_hash.clone(),
        raw_json: raw,
    })
}

fn normalize_script_public_key(value: &str) -> String {
    let script = value.trim().to_ascii_lowercase();
    script
        .strip_prefix("0000")
        .unwrap_or(script.as_str())
        .to_owned()
}

fn address_owner(address: &Address) -> Result<[u8; 32]> {
    if address.version != AddressVersion::PubKey || address.payload.len() != 32 {
        return Err(CoreError::InvalidRequest(
            "KRON requires P2PK addresses".into(),
        ));
    }
    address
        .payload
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidAddress)
}

fn decode_state(template: Vec<u8>) -> Result<State> {
    let hits = (0..template.len().saturating_sub(45))
        .filter(|&s| {
            template[s] == 0x20
                && template[s + 33] == 0x01
                && template[s + 34] == 3
                && template[s + 35] == 0x08
                && template[s + 44] == 0x01
                && template[s + 45] == 0
        })
        .collect::<Vec<_>>();
    if hits.len() != 1 {
        return Err(CoreError::UntrustedUtxo("invalid KRON state layout".into()));
    }
    let s = hits[0];
    let owner = template[s + 1..s + 33]
        .try_into()
        .map_err(|_| CoreError::Serialization)?;
    let amount = u64::from_le_bytes(
        template[s + 36..s + 44]
            .try_into()
            .map_err(|_| CoreError::Serialization)?,
    );
    Ok(State {
        template,
        state_start: s,
        owner,
        amount,
    })
}

fn same_template(a: &State, b: &State) -> bool {
    if a.state_start != b.state_start || a.template.len() != b.template.len() {
        return false;
    }
    a.template
        .iter()
        .enumerate()
        .all(|(i, byte)| (i >= a.state_start && i < a.state_start + 46) || *byte == b.template[i])
}

fn materialize(state: &State, owner: &[u8; 32], amount: u64) -> Vec<u8> {
    let mut out = state.template.clone();
    let s = state.state_start;
    out[s + 1..s + 33].copy_from_slice(owner);
    out[s + 34] = 3;
    out[s + 36..s + 44].copy_from_slice(&amount.to_le_bytes());
    out[s + 45] = 0;
    out
}

fn transfer_sig_script(
    redeem: &[u8],
    states: &[([u8; 32], u64)],
    witnesses: &[u8],
) -> Result<Vec<u8>> {
    let owners = states
        .iter()
        .flat_map(|(owner, _)| owner)
        .copied()
        .collect::<Vec<_>>();
    let types = vec![3u8; states.len()];
    let amounts = states
        .iter()
        .flat_map(|(_, amount)| amount.to_le_bytes())
        .collect::<Vec<_>>();
    let minters = vec![0u8; states.len()];
    let mut builder = ScriptBuilder::with_flags(EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    });
    for data in [
        &owners[..],
        &types,
        &amounts,
        &minters,
        &[][..],
        witnesses,
        redeem,
    ] {
        builder
            .add_data(data)
            .map_err(|e| CoreError::Transaction(e.to_string()))?;
    }
    Ok(builder.drain())
}

#[allow(clippy::too_many_arguments)]
fn make_transaction(
    inputs: Vec<TransactionInput>,
    states: &[([u8; 32], u64)],
    template: &State,
    covenant_id: Hash,
    funding: &crate::transaction::Spendable,
    sender: &Address,
    input_total: u64,
    locked_out: u64,
    fee: u64,
    storage_mass: u64,
) -> Result<Transaction> {
    let mut inputs = inputs;
    inputs.push(TransactionInput::new_with_mass(
        funding.outpoint,
        vec![],
        0,
        ComputeCommit::ComputeBudget(FUNDING_COMPUTE_BUDGET.into()),
    ));
    let mut outputs = states
        .iter()
        .map(|(owner, amount)| {
            TransactionOutput::with_covenant(
                TOKEN_CELL_VALUE,
                pay_to_script_hash_script(&materialize(template, owner, *amount)),
                Some(CovenantBinding::new(0, covenant_id)),
            )
        })
        .collect::<Vec<_>>();
    let change = input_total
        .checked_sub(locked_out + fee)
        .ok_or(CoreError::InsufficientFunds)?;
    if change >= 10_000 {
        outputs.push(TransactionOutput::new(
            change,
            pay_to_address_script(sender),
        ));
    }
    Ok(Transaction::new_with_mass(
        TX_VERSION_TOCCATA,
        inputs,
        outputs,
        0,
        SUBNETWORK_ID_NATIVE,
        0,
        vec![],
        storage_mass,
    ))
}

fn script_json(script: &kaspa_consensus_core::tx::ScriptPublicKey) -> String {
    let mut bytes = script.version().to_be_bytes().to_vec();
    bytes.extend_from_slice(script.script());
    hex::encode(bytes)
}

fn safe_json(tx: &Transaction, entries: &[UtxoEntry]) -> serde_json::Value {
    json!({
        "version": tx.version,
        "inputs": tx.inputs.iter().zip(entries).map(|(input, entry)| json!({
            "transactionId": input.previous_outpoint.transaction_id.to_string(), "index": input.previous_outpoint.index,
            "sequence": input.sequence.to_string(), "sigOpCount": input.compute_commit.sig_op_count().unwrap_or_default(),
            "computeBudget": input.compute_commit.compute_budget().unwrap_or_default(), "signatureScript": hex::encode(&input.signature_script),
            "utxo": { "amount": entry.amount.to_string(), "scriptPublicKey": script_json(&entry.script_public_key), "blockDaaScore": entry.block_daa_score.to_string(), "isCoinbase": entry.is_coinbase, "covenantId": entry.covenant_id.map(|id| id.to_string()) }
        })).collect::<Vec<_>>(),
        "outputs": tx.outputs.iter().map(|output| json!({ "value": output.value.to_string(), "scriptPublicKey": script_json(&output.script_public_key), "covenant": output.covenant.map(|binding| json!({"authorizingInput": binding.authorizing_input, "covenantId": binding.covenant_id.to_string()})) })).collect::<Vec<_>>(),
        "subnetworkId": tx.subnetwork_id.to_string(), "lockTime": tx.lock_time.to_string(), "gas": tx.gas.to_string(), "storageMass": tx.storage_mass().to_string(), "payload": hex::encode(&tx.payload)
    })
}
