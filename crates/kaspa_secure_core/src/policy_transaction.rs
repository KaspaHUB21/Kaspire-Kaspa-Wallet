use crate::{derive_address, derive_key, CoreError, Result};
use kaspa_addresses::Address;
use kaspa_consensus_core::{
    hashing::sighash_type::SIG_HASH_ALL,
    sign::sign_input,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ScriptPublicKey, SignableTransaction, Transaction, TransactionInput, TransactionOutpoint,
        TransactionOutput, UtxoEntry,
    },
};
use kaspa_txscript::{
    opcodes::codes::{
        OpCheckLockTimeVerify, OpCheckSequenceVerify, OpCheckSigVerify, OpElse, OpEndIf,
        OpEqualVerify, OpGreaterThanOrEqual, OpIf, OpNumEqualVerify, OpSub,
        OpTrue, OpTxInputAmount, OpTxInputCount, OpTxInputIndex, OpTxInputSpk,
        OpTxOutputAmount, OpTxOutputCount, OpTxOutputSpk, OpVerify,
    },
    pay_to_address_script, script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, str::FromStr};

const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_VAULT_FEE_SOMPI: u64 = 15_000_000;
const VAULT_PROTOCOL: &str = "kaslab-time-lock-vault-v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyTransactionRequest {
    pub sender: String,
    pub tx_json_string: String,
    pub sign_input_indexes: Vec<usize>,
    #[serde(default)]
    pub redeem_script: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedPolicyTransaction {
    pub profile: String,
    pub action: String,
    pub sender: String,
    pub input_count: usize,
    pub output_count: usize,
    pub fee_sompi: u64,
    pub vault_amount_sompi: u64,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedPolicyTransaction {
    pub signed_tx_json: String,
    pub fee_sompi: u64,
    pub review_hash: String,
}

struct BuiltPolicyTransaction {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    json: Value,
    review: PreparedPolicyTransaction,
}

pub fn prepare_policy_transaction(
    request: &PolicyTransactionRequest,
) -> Result<PreparedPolicyTransaction> {
    Ok(build_policy_transaction(request)?.review)
}

pub fn sign_policy_transaction(
    secret: &str,
    request: &PolicyTransactionRequest,
    approved_review_hash: &str,
) -> Result<SignedPolicyTransaction> {
    if derive_address(secret)?.to_string() != request.sender {
        return Err(CoreError::InvalidRequest(
            "seed does not control policy transaction sender".into(),
        ));
    }
    let mut built = build_policy_transaction(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = derive_key(secret)?;
    let populated =
        SignableTransaction::with_entries(built.tx.clone(), built.entries.clone());
    for index in &request.sign_input_indexes {
        let signature = sign_input(&populated.as_verifiable(), *index, &*key, SIG_HASH_ALL);
        built.tx.inputs[*index].signature_script = signature.clone();
        built.json["inputs"][*index]["signatureScript"] = Value::String(hex::encode(signature));
    }
    built.tx.finalize();
    built.json["id"] = Value::String(built.tx.id().to_string());
    Ok(SignedPolicyTransaction {
        signed_tx_json: serde_json::to_string(&built.json)
            .map_err(|_| CoreError::Serialization)?,
        fee_sompi: built.review.fee_sompi,
        review_hash: built.review.review_hash,
    })
}

fn build_policy_transaction(request: &PolicyTransactionRequest) -> Result<BuiltPolicyTransaction> {
    let value: Value = serde_json::from_str(&request.tx_json_string)
        .map_err(|_| CoreError::InvalidRequest("invalid transaction SafeJSON".into()))?;
    let payload_hex = value
        .get("payload")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing vault payload".into()))?;
    let payload: Value = serde_json::from_slice(
        &hex::decode(payload_hex)
            .map_err(|_| CoreError::InvalidRequest("invalid vault payload".into()))?,
    )
    .map_err(|_| CoreError::InvalidRequest("invalid vault payload JSON".into()))?;
    match payload.get("action").and_then(Value::as_str) {
        Some("create" | "dms-create") => build_vault_create(request),
        Some("dms-heartbeat") => build_vault_heartbeat(request),
        _ => Err(CoreError::InvalidRequest(
            "unsupported policy transaction profile".into(),
        )),
    }
}

fn build_vault_create(request: &PolicyTransactionRequest) -> Result<BuiltPolicyTransaction> {
    if request.tx_json_string.len() > MAX_REQUEST_BYTES
        || request.sign_input_indexes != [0]
        || !request.redeem_script.is_empty()
    {
        return Err(CoreError::InvalidRequest("invalid vault-create request".into()));
    }
    let sender = Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let value: Value = serde_json::from_str(&request.tx_json_string)
        .map_err(|_| CoreError::InvalidRequest("invalid transaction SafeJSON".into()))?;
    let version = u16_value(value.get("version"))?;
    if version != 0
        || u64_value(value.get("lockTime"))? != 0
        || u64_value(value.get("gas"))? != 0
        || value.get("subnetworkId").and_then(Value::as_str)
            != Some(SUBNETWORK_ID_NATIVE.to_string().as_str())
    {
        return Err(CoreError::InvalidRequest("unsupported vault-create envelope".into()));
    }
    let payload_bytes = hex::decode(
        value.get("payload").and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing vault payload".into()))?,
    ).map_err(|_| CoreError::InvalidRequest("invalid vault payload".into()))?;
    let payload: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|_| CoreError::InvalidRequest("invalid vault payload JSON".into()))?;
    let action = payload.get("action").and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing vault action".into()))?;
    if payload.get("p").and_then(Value::as_str) != Some(VAULT_PROTOCOL)
        || payload.get("v").and_then(Value::as_u64) != Some(2)
        || !matches!(action, "create" | "dms-create")
        || payload.get("ownerAddress").and_then(Value::as_str) != Some(request.sender.as_str())
    {
        return Err(CoreError::InvalidRequest("inconsistent vault-create policy".into()));
    }
    let inputs_json = value.get("inputs").and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing inputs".into()))?;
    let outputs_json = value.get("outputs").and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing outputs".into()))?;
    let expected_outputs = if action == "dms-create" { 3 } else { 2 };
    if inputs_json.len() != 1 || outputs_json.len() != expected_outputs {
        return Err(CoreError::InvalidRequest("unexpected vault-create shape".into()));
    }
    let item = &inputs_json[0];
    if item.get("signatureScript").and_then(Value::as_str).unwrap_or("") != "" {
        return Err(CoreError::InvalidRequest("pre-signed request rejected".into()));
    }
    let txid = kaspa_consensus_core::tx::TransactionId::from_str(
        item.get("transactionId").and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing transaction id".into()))?
    ).map_err(|_| CoreError::UntrustedUtxo("invalid transaction id".into()))?;
    let utxo = item.get("utxo")
        .ok_or_else(|| CoreError::UntrustedUtxo("missing embedded UTXO".into()))?;
    if utxo.get("isCoinbase").and_then(Value::as_bool) != Some(false) {
        return Err(CoreError::UntrustedUtxo("coinbase or unknown maturity".into()));
    }
    let input_amount = u64_value(utxo.get("amount"))?;
    let input_script = script_public_key(utxo.get("scriptPublicKey").and_then(Value::as_str)
        .ok_or_else(|| CoreError::UntrustedUtxo("missing UTXO script".into()))?)?;
    if input_script != pay_to_address_script(&sender) {
        return Err(CoreError::UntrustedUtxo("input is not controlled by sender".into()));
    }
    let entry = UtxoEntry::new(input_amount, input_script, u64_value(utxo.get("blockDaaScore")).unwrap_or(0), false, None);
    let input = TransactionInput::new(
        TransactionOutpoint::new(txid, u32_value(item.get("index"))?),
        vec![], u64_value(item.get("sequence"))?,
        u64_value(item.get("sigOpCount"))?.try_into()
            .map_err(|_| CoreError::InvalidRequest("sigop count exceeds u8".into()))?,
    );
    let mut outputs = Vec::with_capacity(expected_outputs);
    let mut output_total = 0u64;
    for output in outputs_json {
        let amount = u64_value(output.get("value"))?;
        output_total = output_total.checked_add(amount)
            .ok_or_else(|| CoreError::InvalidRequest("output amount overflow".into()))?;
        outputs.push(TransactionOutput::new(amount, script_public_key(
            output.get("scriptPublicKey").and_then(Value::as_str)
                .ok_or_else(|| CoreError::InvalidRequest("missing output script".into()))?
        )?));
    }
    let vault_amount = payload.get("lockAmountSompi").and_then(Value::as_str)
        .and_then(|raw| raw.parse::<u64>().ok())
        .ok_or_else(|| CoreError::InvalidRequest("invalid locked amount".into()))?;
    let vault_address = Address::try_from(payload.get("vaultAddress").and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing vault address".into()))?)
        .map_err(|_| CoreError::InvalidAddress)?;
    let redeem = hex::decode(payload.get("redeemScript").and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing redeem script".into()))?)
        .map_err(|_| CoreError::InvalidRequest("invalid redeem script".into()))?;
    let expected_redeem = expected_vault_redeem_script(&payload, &sender, action)?;
    if redeem != expected_redeem {
        return Err(CoreError::InvalidRequest(
            "vault redeem script does not match the native policy template".into(),
        ));
    }
    let vault_script = kaspa_txscript::pay_to_script_hash_script(&redeem);
    if outputs[0].value != vault_amount
        || outputs[0].script_public_key != vault_script
        || pay_to_address_script(&vault_address) != vault_script
        || outputs.last().unwrap().script_public_key != pay_to_address_script(&sender)
    {
        return Err(CoreError::InvalidRequest("vault output policy mismatch".into()));
    }
    if action == "dms-create" {
        let beneficiary = Address::try_from(payload.get("beneficiaryAddress").and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing beneficiary".into()))?)
            .map_err(|_| CoreError::InvalidAddress)?;
        if outputs[1].value != 3_000_000
            || outputs[1].script_public_key != pay_to_address_script(&beneficiary)
        {
            return Err(CoreError::InvalidRequest("beneficiary notice mismatch".into()));
        }
    }
    let fee = input_amount.checked_sub(output_total)
        .ok_or_else(|| CoreError::InvalidRequest("outputs exceed input".into()))?;
    if fee == 0 || fee > MAX_VAULT_FEE_SOMPI {
        return Err(CoreError::InvalidRequest("vault fee exceeds safety policy".into()));
    }
    let mut tx = Transaction::new(version, vec![input], outputs, 0, SUBNETWORK_ID_NATIVE, 0, payload_bytes);
    tx.finalize();
    if let Some(id) = value.get("id").and_then(Value::as_str) {
        if id != tx.id().to_string() {
            return Err(CoreError::InvalidRequest("transaction id mismatch".into()));
        }
    }
    let review_data = json!({
        "network":"kaspa:mainnet","profile":format!("vault-{action}-v2"),
        "action":action,"sender":request.sender,"vaultAddress":vault_address.to_string(),
        "vaultAmountSompi":vault_amount,"feeSompi":fee,"transactionId":tx.id().to_string()
    });
    let review_hash = hex::encode(Sha256::digest(
        serde_json::to_vec(&review_data).map_err(|_| CoreError::Serialization)?
    ));
    Ok(BuiltPolicyTransaction {
        tx, entries: vec![entry], json: value,
        review: PreparedPolicyTransaction {
            profile: format!("vault-{action}-v2"), action: action.into(),
            sender: request.sender.clone(), input_count: 1,
            output_count: expected_outputs, fee_sompi: fee,
            vault_amount_sompi: vault_amount, review_hash,
        }
    })
}

fn expected_vault_redeem_script(payload: &Value, sender: &Address, action: &str) -> Result<Vec<u8>> {
    let mut builder = ScriptBuilder::new();
    if action == "create" {
        let unlock_time = payload.get("unlockTime").and_then(Value::as_str)
            .and_then(|raw| raw.parse::<u64>().ok())
            .ok_or_else(|| CoreError::InvalidRequest("invalid unlock time".into()))?;
        let owner_script = script_with_version(&pay_to_address_script(sender));
        if payload.get("pinnedOwnerAddress").and_then(Value::as_str) != Some(sender.to_string().as_str())
            || payload.get("pinnedOwnerScriptPublicKey").and_then(Value::as_str)
                != Some(hex::encode(&owner_script).as_str())
        {
            return Err(CoreError::InvalidRequest("pinned owner policy mismatch".into()));
        }
        builder.add_lock_time(unlock_time)
            .and_then(|b| b.add_op(OpCheckLockTimeVerify))
            .and_then(|b| b.add_op(OpTxInputCount))
            .and_then(|b| b.add_i64(1))
            .and_then(|b| b.add_op(OpNumEqualVerify))
            .and_then(|b| b.add_op(OpTxOutputCount))
            .and_then(|b| b.add_i64(1))
            .and_then(|b| b.add_op(OpNumEqualVerify))
            .and_then(|b| b.add_i64(0))
            .and_then(|b| b.add_op(OpTxOutputSpk))
            .and_then(|b| b.add_data(&owner_script))
            .and_then(|b| b.add_op(OpEqualVerify))
            .and_then(|b| b.add_i64(0))
            .and_then(|b| b.add_op(OpTxOutputAmount))
            .and_then(|b| b.add_op(OpTxInputIndex))
            .and_then(|b| b.add_op(OpTxInputAmount))
            .and_then(|b| b.add_i64(MAX_VAULT_FEE_SOMPI as i64))
            .and_then(|b| b.add_op(OpSub))
            .and_then(|b| b.add_op(OpGreaterThanOrEqual))
            .and_then(|b| b.add_op(OpVerify))
            .and_then(|b| b.add_op(OpTrue))
            .map_err(|error| CoreError::Transaction(error.to_string()))?;
        return Ok(builder.drain());
    }

    let beneficiary = Address::try_from(
        payload.get("beneficiaryAddress").and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing beneficiary".into()))?
    ).map_err(|_| CoreError::InvalidAddress)?;
    let beneficiary_script = script_with_version(&pay_to_address_script(&beneficiary));
    let owner_public_key = hex::decode(
        payload.get("ownerPublicKey").and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing owner public key".into()))?
    ).map_err(|_| CoreError::InvalidRequest("invalid owner public key".into()))?;
    if owner_public_key.len() != 32 || owner_public_key.as_slice() != sender.payload.as_slice() {
        return Err(CoreError::InvalidRequest("owner public key mismatch".into()));
    }
    let inactivity = payload.get("inactivityDaaBlocks").and_then(Value::as_str)
        .and_then(|raw| raw.parse::<u64>().ok())
        .ok_or_else(|| CoreError::InvalidRequest("invalid inactivity period".into()))?;
    builder.add_op(OpIf)
        .and_then(|b| b.add_data(&owner_public_key))
        .and_then(|b| b.add_op(OpCheckSigVerify))
        .and_then(|b| b.add_op(OpTxInputCount))
        .and_then(|b| b.add_i64(2))
        .and_then(|b| b.add_op(OpNumEqualVerify))
        .and_then(|b| b.add_op(OpTxOutputCount))
        .and_then(|b| b.add_i64(2))
        .and_then(|b| b.add_op(OpNumEqualVerify))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_op(OpTxOutputSpk))
        .and_then(|b| b.add_op(OpTxInputIndex))
        .and_then(|b| b.add_op(OpTxInputSpk))
        .and_then(|b| b.add_op(OpEqualVerify))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_op(OpTxOutputAmount))
        .and_then(|b| b.add_op(OpTxInputIndex))
        .and_then(|b| b.add_op(OpTxInputAmount))
        .and_then(|b| b.add_op(OpGreaterThanOrEqual))
        .and_then(|b| b.add_op(OpVerify))
        .and_then(|b| b.add_op(OpTrue))
        .and_then(|b| b.add_op(OpElse))
        .and_then(|b| b.add_sequence(inactivity))
        .and_then(|b| b.add_op(OpCheckSequenceVerify))
        .and_then(|b| b.add_op(OpTxInputCount))
        .and_then(|b| b.add_i64(1))
        .and_then(|b| b.add_op(OpNumEqualVerify))
        .and_then(|b| b.add_op(OpTxOutputCount))
        .and_then(|b| b.add_i64(1))
        .and_then(|b| b.add_op(OpNumEqualVerify))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_op(OpTxOutputSpk))
        .and_then(|b| b.add_data(&beneficiary_script))
        .and_then(|b| b.add_op(OpEqualVerify))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_op(OpTxOutputAmount))
        .and_then(|b| b.add_op(OpTxInputIndex))
        .and_then(|b| b.add_op(OpTxInputAmount))
        .and_then(|b| b.add_i64(MAX_VAULT_FEE_SOMPI as i64))
        .and_then(|b| b.add_op(OpSub))
        .and_then(|b| b.add_op(OpGreaterThanOrEqual))
        .and_then(|b| b.add_op(OpVerify))
        .and_then(|b| b.add_op(OpTrue))
        .and_then(|b| b.add_op(OpEndIf))
        .map_err(|error| CoreError::Transaction(error.to_string()))?;
    Ok(builder.drain())
}

fn script_with_version(script: &ScriptPublicKey) -> Vec<u8> {
    let mut bytes = script.version().to_be_bytes().to_vec();
    bytes.extend_from_slice(script.script());
    bytes
}

fn build_vault_heartbeat(request: &PolicyTransactionRequest) -> Result<BuiltPolicyTransaction> {
    if request.tx_json_string.len() > MAX_REQUEST_BYTES {
        return Err(CoreError::InvalidRequest(
            "policy transaction exceeds size limit".into(),
        ));
    }
    let sender = Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let mut value: Value = serde_json::from_str(&request.tx_json_string)
        .map_err(|_| CoreError::InvalidRequest("invalid transaction SafeJSON".into()))?;
    let object = value
        .as_object_mut()
        .ok_or_else(|| CoreError::InvalidRequest("transaction must be an object".into()))?;
    let version = u16_value(object.get("version"))?;
    let lock_time = u64_value(object.get("lockTime"))?;
    let gas = u64_value(object.get("gas"))?;
    let storage_mass = u64_value(object.get("storageMass")).unwrap_or(0);
    let subnetwork = object
        .get("subnetworkId")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing subnetwork".into()))?;
    if version != 1
        || lock_time != 0
        || gas != 0
        || subnetwork != SUBNETWORK_ID_NATIVE.to_string()
    {
        return Err(CoreError::InvalidRequest(
            "unsupported vault transaction envelope".into(),
        ));
    }
    let payload_hex = object
        .get("payload")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing vault payload".into()))?;
    let payload_bytes = hex::decode(payload_hex)
        .map_err(|_| CoreError::InvalidRequest("invalid vault payload".into()))?;
    if payload_bytes.len() > 16 * 1024 {
        return Err(CoreError::InvalidRequest("vault payload is too large".into()));
    }
    let payload: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|_| CoreError::InvalidRequest("invalid vault payload JSON".into()))?;
    if payload.get("p").and_then(Value::as_str) != Some(VAULT_PROTOCOL)
        || payload.get("v").and_then(Value::as_u64) != Some(2)
        || payload.get("action").and_then(Value::as_str) != Some("dms-heartbeat")
        || payload.get("dmsMode").and_then(Value::as_str) != Some("heartbeat")
        || payload.get("refreshMode").and_then(Value::as_str)
            != Some("covenant-utxo-recreation")
        || payload.get("ownerAddress").and_then(Value::as_str) != Some(request.sender.as_str())
    {
        return Err(CoreError::InvalidRequest(
            "unsupported or inconsistent vault policy".into(),
        ));
    }

    let inputs_json = object
        .get("inputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing inputs".into()))?;
    let outputs_json = object
        .get("outputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing outputs".into()))?;
    if inputs_json.len() != 2
        || outputs_json.len() != 2
        || request.sign_input_indexes != [0, 1]
    {
        return Err(CoreError::InvalidRequest(
            "heartbeat must sign exactly its covenant and fee inputs".into(),
        ));
    }

    let mut seen = HashSet::new();
    let mut inputs = Vec::with_capacity(2);
    let mut entries = Vec::with_capacity(2);
    let mut input_total = 0u64;
    for (index, item) in inputs_json.iter().enumerate() {
        let txid_raw = item
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing transaction id".into()))?;
        let txid = kaspa_consensus_core::tx::TransactionId::from_str(txid_raw)
            .map_err(|_| CoreError::UntrustedUtxo("invalid transaction id".into()))?;
        let output_index = u32_value(item.get("index"))?;
        if !seen.insert((txid, output_index)) {
            return Err(CoreError::UntrustedUtxo("duplicate input outpoint".into()));
        }
        let utxo = item
            .get("utxo")
            .ok_or_else(|| CoreError::UntrustedUtxo("missing embedded UTXO".into()))?;
        if utxo.get("isCoinbase").and_then(Value::as_bool) != Some(false) {
            return Err(CoreError::UntrustedUtxo(
                "coinbase or unknown UTXO maturity".into(),
            ));
        }
        let amount = u64_value(utxo.get("amount"))?;
        input_total = input_total
            .checked_add(amount)
            .ok_or_else(|| CoreError::InvalidRequest("input amount overflow".into()))?;
        let script = script_public_key(
            utxo.get("scriptPublicKey")
                .and_then(Value::as_str)
                .ok_or_else(|| CoreError::UntrustedUtxo("missing UTXO script".into()))?,
        )?;
        if index == 1 && script != pay_to_address_script(&sender) {
            return Err(CoreError::UntrustedUtxo(
                "heartbeat fee input is not controlled by sender".into(),
            ));
        }
        entries.push(UtxoEntry::new(
            amount,
            script,
            u64_value(utxo.get("blockDaaScore")).unwrap_or(0),
            false,
            None,
        ));
        if item.get("signatureScript").and_then(Value::as_str).unwrap_or("") != "" {
            return Err(CoreError::InvalidRequest(
                "pre-signed policy transactions are rejected".into(),
            ));
        }
        let compute_budget: u16 = u64_value(item.get("computeBudget"))
            .unwrap_or(0)
            .try_into()
            .map_err(|_| CoreError::InvalidRequest("compute budget exceeds u16".into()))?;
        inputs.push(TransactionInput::new_with_compute_budget(
            TransactionOutpoint::new(txid, output_index),
            vec![],
            u64_value(item.get("sequence"))?,
            compute_budget,
        ));
    }

    let mut outputs = Vec::with_capacity(2);
    let mut output_total = 0u64;
    for item in outputs_json {
        let amount = u64_value(item.get("value"))?;
        output_total = output_total
            .checked_add(amount)
            .ok_or_else(|| CoreError::InvalidRequest("output amount overflow".into()))?;
        outputs.push(TransactionOutput::new(
            amount,
            script_public_key(
                item.get("scriptPublicKey")
                    .and_then(Value::as_str)
                    .ok_or_else(|| CoreError::InvalidRequest("missing output script".into()))?,
            )?,
        ));
    }
    if entries[0].amount != outputs[0].value
        || entries[0].script_public_key != outputs[0].script_public_key
        || outputs[1].script_public_key != pay_to_address_script(&sender)
    {
        return Err(CoreError::InvalidRequest(
            "heartbeat may only recreate the vault and return sender change".into(),
        ));
    }
    let fee = input_total
        .checked_sub(output_total)
        .ok_or_else(|| CoreError::InvalidRequest("outputs exceed inputs".into()))?;
    if fee == 0 || fee > MAX_VAULT_FEE_SOMPI {
        return Err(CoreError::InvalidRequest("vault fee exceeds safety policy".into()));
    }
    let redeem = hex::decode(request.redeem_script.trim_start_matches("0x"))
        .map_err(|_| CoreError::InvalidRequest("invalid redeem script".into()))?;
    if redeem.is_empty() {
        return Err(CoreError::InvalidRequest("redeem script is required".into()));
    }
    let expected_vault_script = kaspa_txscript::pay_to_script_hash_script(&redeem);
    if entries[0].script_public_key != expected_vault_script {
        return Err(CoreError::InvalidRequest(
            "redeem script does not bind the covenant input".into(),
        ));
    }
    let vault_address = payload
        .get("vaultAddress")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing vault address".into()))?;
    let vault_address = Address::try_from(vault_address).map_err(|_| CoreError::InvalidAddress)?;
    if pay_to_address_script(&vault_address) != expected_vault_script {
        return Err(CoreError::InvalidRequest("vault address mismatch".into()));
    }

    let mut tx = Transaction::new(
        version,
        inputs,
        outputs,
        lock_time,
        SUBNETWORK_ID_NATIVE,
        gas,
        payload_bytes,
    );
    tx.set_storage_mass(storage_mass);
    tx.finalize();
    if let Some(id) = object.get("id").and_then(Value::as_str) {
        if id != tx.id().to_string() {
            return Err(CoreError::InvalidRequest("transaction id mismatch".into()));
        }
    }
    let review_data = json!({
        "network":"kaspa:mainnet", "profile":"vault-dms-heartbeat-v2",
        "action":"dms-heartbeat", "sender":request.sender,
        "vaultAddress":vault_address.to_string(), "vaultAmountSompi":entries[0].amount,
        "feeSompi":fee, "transactionId":tx.id().to_string(),
        "signInputIndexes":request.sign_input_indexes,
        "redeemScriptHash":hex::encode(Sha256::digest(&redeem))
    });
    let review_hash = hex::encode(Sha256::digest(
        serde_json::to_vec(&review_data).map_err(|_| CoreError::Serialization)?,
    ));
    Ok(BuiltPolicyTransaction {
        tx,
        entries,
        json: value,
        review: PreparedPolicyTransaction {
            profile: "vault-dms-heartbeat-v2".into(),
            action: "dms-heartbeat".into(),
            sender: request.sender.clone(),
            input_count: 2,
            output_count: 2,
            fee_sompi: fee,
            vault_amount_sompi: review_data["vaultAmountSompi"].as_u64().unwrap(),
            review_hash,
        },
    })
}

fn script_public_key(raw: &str) -> Result<ScriptPublicKey> {
    let bytes = hex::decode(raw)
        .map_err(|_| CoreError::UntrustedUtxo("invalid script encoding".into()))?;
    if bytes.len() < 2 {
        return Err(CoreError::UntrustedUtxo("short script encoding".into()));
    }
    let version = u16::from_be_bytes([bytes[0], bytes[1]]);
    Ok(ScriptPublicKey::new(version, bytes[2..].to_vec().into()))
}

fn u64_value(value: Option<&Value>) -> Result<u64> {
    value
        .and_then(|value| match value {
            Value::String(raw) => raw.parse().ok(),
            Value::Number(number) => number.as_u64(),
            _ => None,
        })
        .ok_or_else(|| CoreError::InvalidRequest("invalid integer field".into()))
}

fn u32_value(value: Option<&Value>) -> Result<u32> {
    u64_value(value)?
        .try_into()
        .map_err(|_| CoreError::InvalidRequest("integer exceeds u32".into()))
}

fn u16_value(value: Option<&Value>) -> Result<u16> {
    u64_value(value)?
        .try_into()
        .map_err(|_| CoreError::InvalidRequest("integer exceeds u16".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_txscript::pay_to_script_hash_script;

    const ADDRESS: &str =
        "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";

    fn script_json(script: &ScriptPublicKey) -> String {
        let mut bytes = script.version().to_be_bytes().to_vec();
        bytes.extend_from_slice(script.script());
        hex::encode(bytes)
    }

    fn request() -> PolicyTransactionRequest {
        let sender = Address::try_from(ADDRESS).unwrap();
        let owner_script = pay_to_address_script(&sender);
        let redeem = vec![0x51];
        let vault_script = pay_to_script_hash_script(&redeem);
        let payload = json!({
            "p":VAULT_PROTOCOL, "v":2, "action":"dms-heartbeat",
            "dmsMode":"heartbeat", "refreshMode":"covenant-utxo-recreation",
            "ownerAddress":ADDRESS, "vaultAddress":
                kaspa_txscript::extract_script_pub_key_address(
                    &vault_script, kaspa_addresses::Prefix::Mainnet
                ).unwrap().to_string()
        });
        let safe = json!({
            "version":1,
            "inputs":[
                {"transactionId":"11".repeat(32),"index":0,"sequence":"0",
                 "sigOpCount":1,"computeBudget":1000,"signatureScript":"",
                 "utxo":{"amount":"200000000","scriptPublicKey":script_json(&vault_script),
                    "blockDaaScore":"100","isCoinbase":false}},
                {"transactionId":"22".repeat(32),"index":1,"sequence":"0",
                 "sigOpCount":1,"computeBudget":0,"signatureScript":"",
                 "utxo":{"amount":"10000000","scriptPublicKey":script_json(&owner_script),
                    "blockDaaScore":"100","isCoinbase":false}}
            ],
            "outputs":[
                {"value":"200000000","scriptPublicKey":script_json(&vault_script)},
                {"value":"9000000","scriptPublicKey":script_json(&owner_script)}
            ],
            "subnetworkId":SUBNETWORK_ID_NATIVE.to_string(),
            "lockTime":"0","gas":"0","storageMass":"0",
            "payload":hex::encode(serde_json::to_vec(&payload).unwrap())
        });
        PolicyTransactionRequest {
            sender: ADDRESS.into(),
            tx_json_string: safe.to_string(),
            sign_input_indexes: vec![0, 1],
            redeem_script: hex::encode(redeem),
        }
    }

    fn create_request() -> PolicyTransactionRequest {
        let sender = Address::try_from(ADDRESS).unwrap();
        let owner_script = pay_to_address_script(&sender);
        let owner_script_hex = script_json(&owner_script);
        let mut payload = json!({
            "p":VAULT_PROTOCOL, "v":2, "action":"create",
            "ownerAddress":ADDRESS, "pinnedOwnerAddress":ADDRESS,
            "pinnedOwnerScriptPublicKey":owner_script_hex,
            "unlockTime":"500000000", "lockAmountSompi":"10000000",
            "vaultAddress":""
        });
        let redeem = expected_vault_redeem_script(&payload, &sender, "create").unwrap();
        payload["redeemScript"] = json!(hex::encode(&redeem));
        let vault_script = pay_to_script_hash_script(&redeem);
        payload["vaultAddress"] = json!(
            kaspa_txscript::extract_script_pub_key_address(
                &vault_script, kaspa_addresses::Prefix::Mainnet
            ).unwrap().to_string()
        );
        let safe = json!({
            "version":0,
            "inputs":[{
                "transactionId":"33".repeat(32),"index":0,"sequence":"0",
                "sigOpCount":1,"computeBudget":0,"signatureScript":"",
                "utxo":{"amount":"30000000","scriptPublicKey":script_json(&owner_script),
                    "blockDaaScore":"100","isCoinbase":false}
            }],
            "outputs":[
                {"value":"10000000","scriptPublicKey":script_json(&vault_script)},
                {"value":"19000000","scriptPublicKey":script_json(&owner_script)}
            ],
            "subnetworkId":SUBNETWORK_ID_NATIVE.to_string(),
            "lockTime":"0","gas":"0","storageMass":"0",
            "payload":hex::encode(serde_json::to_vec(&payload).unwrap())
        });
        PolicyTransactionRequest {
            sender: ADDRESS.into(), tx_json_string: safe.to_string(),
            sign_input_indexes: vec![0], redeem_script: String::new(),
        }
    }

    #[test]
    fn heartbeat_is_review_bound_and_signs_only_expected_inputs() {
        let request = request();
        let prepared = prepare_policy_transaction(&request).unwrap();
        assert_eq!(prepared.fee_sompi, 1_000_000);
        let secret = "mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        assert!(matches!(
            sign_policy_transaction(secret, &request, "wrong"),
            Err(CoreError::ReviewMismatch)
        ));
        let signed =
            sign_policy_transaction(secret, &request, &prepared.review_hash).unwrap();
        let value: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
        assert!(!value["inputs"][0]["signatureScript"]
            .as_str()
            .unwrap()
            .is_empty());
        assert!(!value["inputs"][1]["signatureScript"]
            .as_str()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn hostile_heartbeat_mutations_fail_closed() {
        let base = request();
        for mutate in 0..5 {
            let mut request = base.clone();
            let mut value: Value = serde_json::from_str(&request.tx_json_string).unwrap();
            match mutate {
                0 => value["outputs"][0]["value"] = json!("199999999"),
                1 => value["outputs"][1]["scriptPublicKey"] = json!("000051"),
                2 => {
                    value["inputs"][1]["transactionId"] =
                        value["inputs"][0]["transactionId"].clone();
                    value["inputs"][1]["index"] = value["inputs"][0]["index"].clone();
                }
                3 => value["payload"] = json!(hex::encode(b"{\"p\":\"evil\"}")),
                _ => request.redeem_script = "52".into(),
            }
            request.tx_json_string = value.to_string();
            assert!(
                prepare_policy_transaction(&request).is_err(),
                "accepted hostile mutation {mutate}"
            );
        }
    }

    #[test]
    fn create_profile_requires_the_exact_native_redeem_template() {
        let request = create_request();
        let prepared = prepare_policy_transaction(&request).unwrap();
        assert_eq!(prepared.profile, "vault-create-v2");
        let mut hostile = request;
        let mut value: Value = serde_json::from_str(&hostile.tx_json_string).unwrap();
        let mut payload: Value = serde_json::from_slice(
            &hex::decode(value["payload"].as_str().unwrap()).unwrap()
        ).unwrap();
        payload["redeemScript"] = json!("51");
        value["payload"] = json!(hex::encode(serde_json::to_vec(&payload).unwrap()));
        hostile.tx_json_string = value.to_string();
        assert!(prepare_policy_transaction(&hostile).is_err());
    }
}
