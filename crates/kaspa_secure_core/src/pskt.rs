#[cfg(test)]
use crate::derive_address;
use crate::{controls_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix};
use kaspa_consensus_core::{
    hashing::sighash_type::{SigHashType, SIG_HASH_ALL},
    sign::sign_input,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        CovenantBinding, ScriptPublicKey, SignableTransaction, Transaction, TransactionInput,
        TransactionOutpoint, TransactionOutput, UtxoEntry,
    },
};
use kaspa_hashes::Hash;
use kaspa_txscript::{extract_script_pub_key_address, pay_to_address_script};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    str::FromStr,
};

use kaspa_txscript::{
    pay_to_script_hash_script, pay_to_script_hash_signature_script_with_flags,
    script_builder::ScriptBuilder, EngineFlags,
};

const MAX_PSKT_BYTES: usize = 512 * 1024;
const MAX_INPUTS: usize = 256;
const MAX_OUTPUTS: usize = 256;
const MAX_PAYLOAD_BYTES: usize = 64 * 1024;
const MAX_SCRIPT_REQUEST_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktSignInput {
    pub index: usize,
    #[serde(default = "default_sighash")]
    pub sighash_type: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum PsktSignatureScriptMode {
    WrapSignature,
    SignatureFirstArgs,
    OrderedArgs,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum PsktScriptArgument {
    I64 {
        value: Value,
    },
    Data {
        hex: String,
    },
    Byte {
        value: u8,
    },
    Signature {
        #[serde(default, rename = "prefixHex")]
        prefix_hex: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktSignatureScriptTemplate {
    pub mode: PsktSignatureScriptMode,
    #[serde(default)]
    pub args: Vec<PsktScriptArgument>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktScriptInput {
    pub input_index: usize,
    pub script_hex: String,
    #[serde(default)]
    pub sign_type: Option<u8>,
    #[serde(default)]
    pub signature_script: Option<PsktSignatureScriptTemplate>,
}

fn default_sighash() -> u8 {
    SIG_HASH_ALL.to_u8()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktRequest {
    pub sender: String,
    #[serde(alias = "psktTransactionJson")]
    pub tx_json_string: String,
    #[serde(default)]
    pub sign_inputs: Vec<PsktSignInput>,
    #[serde(default)]
    pub scripts: Vec<PsktScriptInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PsktInputReview {
    pub index: usize,
    pub outpoint: String,
    pub amount_sompi: u64,
    pub address: Option<String>,
    pub script_public_key: String,
    pub selected: bool,
    pub controlled_by_wallet: bool,
    pub already_signed: bool,
    pub sighash_type: Option<u8>,
    pub sighash_label: Option<String>,
    pub script_aware: bool,
    pub signature_script_mode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PsktOutputReview {
    pub index: usize,
    pub amount_sompi: u64,
    pub address: Option<String>,
    pub script_public_key: String,
    pub returns_to_wallet: bool,
    pub covenant_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedPskt {
    pub profile: String,
    pub sender: String,
    pub transaction_id: String,
    pub version: u16,
    pub input_count: usize,
    pub output_count: usize,
    pub selected_input_count: usize,
    pub input_total_sompi: u64,
    pub output_total_sompi: u64,
    pub fee_sompi: u64,
    pub wallet_input_sompi: u64,
    pub wallet_output_sompi: u64,
    pub wallet_net_sompi: i128,
    pub payload_hex: String,
    pub payload_utf8: Option<String>,
    pub inputs: Vec<PsktInputReview>,
    pub outputs: Vec<PsktOutputReview>,
    pub warnings: Vec<String>,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedPskt {
    pub signed_tx_json: String,
    pub submit_json: Option<String>,
    pub transaction_id: String,
    pub signed_input_indexes: Vec<usize>,
    pub review_hash: String,
}

struct BuiltPskt {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    json: Value,
    sighashes: Vec<(usize, SigHashType)>,
    scripts: HashMap<usize, PsktScriptInput>,
    review: PreparedPskt,
}

pub fn prepare_pskt(request: &PsktRequest) -> Result<PreparedPskt> {
    Ok(build_pskt(request)?.review)
}

pub fn sign_pskt(
    secret: &str,
    request: &PsktRequest,
    approved_review_hash: &str,
) -> Result<SignedPskt> {
    if !controls_address(secret, &request.sender)? {
        return Err(CoreError::InvalidRequest(
            "seed does not control PSKT session address".into(),
        ));
    }
    let mut built = build_pskt(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = derive_key(secret)?;
    let populated = SignableTransaction::with_entries(built.tx.clone(), built.entries.clone());
    for (index, sighash) in &built.sighashes {
        let pushed_signature = sign_input(&populated.as_verifiable(), *index, &*key, *sighash);
        let signature_script = if let Some(script) = built.scripts.get(index) {
            assemble_p2sh_signature_script(script, &pushed_signature)?
        } else {
            pushed_signature
        };
        built.tx.inputs[*index].signature_script = signature_script.clone();
        built.json["inputs"][*index]["signatureScript"] =
            Value::String(hex::encode(signature_script));
    }
    built.tx.finalize();
    let submit_json = crate::transaction::submit_json(&built.tx).ok();
    Ok(SignedPskt {
        signed_tx_json: serde_json::to_string(&built.json).map_err(|_| CoreError::Serialization)?,
        submit_json,
        transaction_id: built.tx.id().to_string(),
        signed_input_indexes: built.sighashes.iter().map(|(index, _)| *index).collect(),
        review_hash: built.review.review_hash,
    })
}

fn build_pskt(request: &PsktRequest) -> Result<BuiltPskt> {
    if request.tx_json_string.is_empty() || request.tx_json_string.len() > MAX_PSKT_BYTES {
        return Err(CoreError::InvalidRequest("PSKT exceeds size limit".into()));
    }
    if serde_json::to_vec(&request.scripts)
        .map_err(|_| CoreError::Serialization)?
        .len()
        > MAX_SCRIPT_REQUEST_BYTES
    {
        return Err(CoreError::InvalidRequest(
            "PSKT script request exceeds size limit".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let sender_script = pay_to_address_script(&sender);
    let mut value: Value = serde_json::from_str(&request.tx_json_string)
        .map_err(|_| CoreError::InvalidRequest("invalid transaction SafeJSON".into()))?;
    let object = value
        .as_object_mut()
        .ok_or_else(|| CoreError::InvalidRequest("transaction must be an object".into()))?;
    let version = u16_value(object.get("version"))?;
    if version > 1 {
        return Err(CoreError::InvalidRequest(
            "unsupported transaction version".into(),
        ));
    }
    let lock_time = u64_value(object.get("lockTime"))?;
    let gas = u64_value(object.get("gas"))?;
    let subnetwork = object
        .get("subnetworkId")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing subnetwork".into()))?;
    if subnetwork != SUBNETWORK_ID_NATIVE.to_string() || gas != 0 {
        return Err(CoreError::InvalidRequest(
            "only native Kaspa transactions are supported".into(),
        ));
    }
    let payload_hex = object
        .get("payload")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidRequest("missing payload".into()))?
        .to_owned();
    let payload = hex::decode(&payload_hex)
        .map_err(|_| CoreError::InvalidRequest("invalid payload encoding".into()))?;
    if payload.len() > MAX_PAYLOAD_BYTES {
        return Err(CoreError::InvalidRequest(
            "payload exceeds size limit".into(),
        ));
    }
    let storage_mass = object
        .get("storageMass")
        .or_else(|| object.get("mass"))
        .map(|value| u64_value(Some(value)))
        .transpose()?
        .unwrap_or(0);

    let inputs_json = object
        .get("inputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing inputs".into()))?;
    let outputs_json = object
        .get("outputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::InvalidRequest("missing outputs".into()))?;
    if inputs_json.is_empty()
        || inputs_json.len() > MAX_INPUTS
        || outputs_json.is_empty()
        || outputs_json.len() > MAX_OUTPUTS
    {
        return Err(CoreError::InvalidRequest(
            "invalid PSKT input or output count".into(),
        ));
    }
    let input_count = inputs_json.len();
    let output_count = outputs_json.len();
    if request.sign_inputs.len() > inputs_json.len() || request.scripts.len() > inputs_json.len() {
        return Err(CoreError::InvalidRequest(
            "invalid selected input count".into(),
        ));
    }
    let mut selected = HashSet::new();
    let mut sighashes_by_index = HashMap::new();
    for selection in &request.sign_inputs {
        if selection.index >= inputs_json.len() || !selected.insert(selection.index) {
            return Err(CoreError::InvalidRequest(
                "duplicate or out-of-range selected input".into(),
            ));
        }
        let sighash = SigHashType::from_u8(selection.sighash_type)
            .map_err(|_| CoreError::InvalidRequest("unsupported sighash type".into()))?;
        if sighash.is_sighash_single() && selection.index >= outputs_json.len() {
            return Err(CoreError::InvalidRequest(
                "SIGHASH_SINGLE input has no matching output".into(),
            ));
        }
        sighashes_by_index.insert(selection.index, sighash);
    }
    let mut scripts = HashMap::new();
    for script in &request.scripts {
        validate_script_request(script, inputs_json.len())?;
        if scripts.insert(script.input_index, script.clone()).is_some() {
            return Err(CoreError::InvalidRequest(
                "duplicate script-aware input".into(),
            ));
        }
        let requested_script_sighash = script.sign_type.unwrap_or_else(|| {
            sighashes_by_index
                .get(&script.input_index)
                .map(|sighash| sighash.to_u8())
                .unwrap_or(default_sighash())
        });
        let script_sighash = SigHashType::from_u8(requested_script_sighash)
            .map_err(|_| CoreError::InvalidRequest("unsupported script sighash type".into()))?;
        if let Some(selected_sighash) = sighashes_by_index.get(&script.input_index) {
            if selected_sighash.to_u8() != script_sighash.to_u8() {
                return Err(CoreError::InvalidRequest(
                    "conflicting sighash types for selected script input".into(),
                ));
            }
        } else {
            selected.insert(script.input_index);
            sighashes_by_index.insert(script.input_index, script_sighash);
        }
    }
    if selected.is_empty() {
        return Err(CoreError::InvalidRequest(
            "no PSKT inputs were selected".into(),
        ));
    }
    let mut sighashes: Vec<(usize, SigHashType)> = sighashes_by_index.into_iter().collect();
    sighashes.sort_by_key(|(index, _)| *index);

    let mut seen_outpoints = HashSet::new();
    let mut inputs = Vec::with_capacity(inputs_json.len());
    let mut entries = Vec::with_capacity(inputs_json.len());
    let mut input_reviews = Vec::with_capacity(inputs_json.len());
    let mut input_total = 0u64;
    let mut wallet_input = 0u64;
    let mut warnings = Vec::new();
    for (index, item) in inputs_json.iter().enumerate() {
        require_object(item, "input")?;
        let txid_raw = item
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing transaction id".into()))?;
        let txid = kaspa_consensus_core::tx::TransactionId::from_str(txid_raw)
            .map_err(|_| CoreError::UntrustedUtxo("invalid transaction id".into()))?;
        let output_index = u32_value(item.get("index"))?;
        if !seen_outpoints.insert((txid, output_index)) {
            return Err(CoreError::UntrustedUtxo("duplicate input outpoint".into()));
        }
        let signature_hex = item
            .get("signatureScript")
            .and_then(Value::as_str)
            .unwrap_or("");
        let signature_script = hex::decode(signature_hex)
            .map_err(|_| CoreError::InvalidRequest("invalid signature script".into()))?;
        if selected.contains(&index) && !signature_script.is_empty() {
            return Err(CoreError::InvalidRequest(
                "selected input is already signed".into(),
            ));
        }
        let utxo = item
            .get("utxo")
            .ok_or_else(|| CoreError::UntrustedUtxo("missing embedded UTXO".into()))?;
        require_object(utxo, "embedded UTXO")?;
        if utxo.get("isCoinbase").and_then(Value::as_bool) != Some(false) {
            return Err(CoreError::UntrustedUtxo(
                "coinbase or unknown UTXO maturity".into(),
            ));
        }
        let amount = u64_value(utxo.get("amount"))?;
        input_total = input_total
            .checked_add(amount)
            .ok_or_else(|| CoreError::InvalidRequest("input amount overflow".into()))?;
        let script_hex = utxo
            .get("scriptPublicKey")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing UTXO script".into()))?;
        let script = script_public_key(script_hex)?;
        if let Some(script_request) = scripts.get(&index) {
            let redeem_script = decode_redeem_script(&script_request.script_hex)?;
            if pay_to_script_hash_script(&redeem_script) != script {
                return Err(CoreError::UntrustedUtxo(format!(
                    "script for input {index} does not match its P2SH UTXO"
                )));
            }
        }
        let controlled = script == sender_script;
        if controlled {
            wallet_input = wallet_input
                .checked_add(amount)
                .ok_or_else(|| CoreError::InvalidRequest("wallet amount overflow".into()))?;
        } else if selected.contains(&index) {
            warnings.push(format!(
                "Input {index} is a covenant or non-standard script; Kaspire cannot verify its dApp business rules."
            ));
        }
        let covenant_id = utxo
            .get("covenantId")
            .and_then(Value::as_str)
            .map(Hash::from_str)
            .transpose()
            .map_err(|_| CoreError::UntrustedUtxo("invalid covenant id".into()))?;
        let entry = UtxoEntry::new(
            amount,
            script.clone(),
            u64_value(utxo.get("blockDaaScore")).unwrap_or(0),
            false,
            covenant_id,
        );
        let sequence = u64_value(item.get("sequence"))?;
        let input = if version == 0 {
            let sigops: u8 = u64_value(item.get("sigOpCount"))?
                .try_into()
                .map_err(|_| CoreError::InvalidRequest("sigop count exceeds u8".into()))?;
            TransactionInput::new(
                TransactionOutpoint::new(txid, output_index),
                signature_script.clone(),
                sequence,
                sigops,
            )
        } else {
            let budget: u16 = u64_value(item.get("computeBudget"))?
                .try_into()
                .map_err(|_| CoreError::InvalidRequest("compute budget exceeds u16".into()))?;
            TransactionInput::new_with_compute_budget(
                TransactionOutpoint::new(txid, output_index),
                signature_script.clone(),
                sequence,
                budget,
            )
        };
        let selection = sighashes
            .iter()
            .find(|(selected_index, _)| *selected_index == index);
        let address = extract_script_pub_key_address(&script, Prefix::Mainnet)
            .ok()
            .map(|address| address.to_string());
        input_reviews.push(PsktInputReview {
            index,
            outpoint: format!("{txid}:{output_index}"),
            amount_sompi: amount,
            address,
            script_public_key: script_hex.to_owned(),
            selected: selection.is_some(),
            controlled_by_wallet: controlled,
            already_signed: !signature_script.is_empty(),
            sighash_type: selection.map(|(_, sighash)| sighash.to_u8()),
            sighash_label: selection.map(|(_, sighash)| sighash_label(*sighash)),
            script_aware: scripts.contains_key(&index),
            signature_script_mode: scripts.get(&index).map(|script| {
                script.signature_script.as_ref().map_or_else(
                    || "wrap-signature".to_owned(),
                    |template| signature_script_mode_label(&template.mode).to_owned(),
                )
            }),
        });
        inputs.push(input);
        entries.push(entry);
    }

    let mut outputs = Vec::with_capacity(outputs_json.len());
    let mut output_reviews = Vec::with_capacity(outputs_json.len());
    let mut output_total = 0u64;
    let mut wallet_output = 0u64;
    for (index, item) in outputs_json.iter().enumerate() {
        require_object(item, "output")?;
        let amount = u64_value(item.get("value"))?;
        output_total = output_total
            .checked_add(amount)
            .ok_or_else(|| CoreError::InvalidRequest("output amount overflow".into()))?;
        let script_hex = item
            .get("scriptPublicKey")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing output script".into()))?;
        let script = script_public_key(script_hex)?;
        let returns = script == sender_script;
        if returns {
            wallet_output = wallet_output
                .checked_add(amount)
                .ok_or_else(|| CoreError::InvalidRequest("wallet amount overflow".into()))?;
        }
        let covenant = parse_covenant(item.get("covenant"), inputs_json.len())?;
        let address = extract_script_pub_key_address(&script, Prefix::Mainnet)
            .ok()
            .map(|address| address.to_string());
        if address.is_none() {
            warnings.push(format!(
                "Output {index} uses a covenant or non-standard script; inspect its script fingerprint."
            ));
        }
        output_reviews.push(PsktOutputReview {
            index,
            amount_sompi: amount,
            address,
            script_public_key: script_hex.to_owned(),
            returns_to_wallet: returns,
            covenant_id: covenant.map(|binding| binding.covenant_id.to_string()),
        });
        outputs.push(TransactionOutput::with_covenant(amount, script, covenant));
    }
    if output_total > input_total {
        return Err(CoreError::InvalidRequest(
            "outputs exceed embedded UTXO value".into(),
        ));
    }
    let fee = input_total - output_total;
    if fee > input_total / 10 && fee > 10_000_000 {
        warnings.push("Network fee exceeds 10% of all transaction inputs.".into());
    }
    if sighashes.len() != inputs_json.len() {
        warnings.push("This is a partial signature; other parties may add signatures.".into());
    }
    for (_, sighash) in &sighashes {
        if sighash.to_u8() != SIG_HASH_ALL.to_u8() {
            warnings.push(format!(
                "{} permits parts of the transaction to change after signing.",
                sighash_label(*sighash)
            ));
        }
    }
    warnings.sort();
    warnings.dedup();

    let tx = Transaction::new_with_mass(
        version,
        inputs,
        outputs,
        lock_time,
        SUBNETWORK_ID_NATIVE,
        gas,
        payload.clone(),
        storage_mass,
    );
    if let Some(id) = object.get("id").and_then(Value::as_str) {
        if !id.is_empty() && id != tx.id().to_string() {
            return Err(CoreError::InvalidRequest(
                "declared transaction id does not match transaction".into(),
            ));
        }
    }
    let payload_utf8 = std::str::from_utf8(&payload)
        .ok()
        .filter(|text| {
            !text
                .chars()
                .any(|ch| ch.is_control() && !ch.is_whitespace())
        })
        .map(ToOwned::to_owned);
    let review_data = json!({
        "profile": "generic-pskt-v2",
        "sender": request.sender,
        "transactionId": tx.id().to_string(),
        "version": version,
        "inputTotalSompi": input_total.to_string(),
        "outputTotalSompi": output_total.to_string(),
        "feeSompi": fee.to_string(),
        "walletInputSompi": wallet_input.to_string(),
        "walletOutputSompi": wallet_output.to_string(),
        "payloadHex": payload_hex,
        "inputs": input_reviews,
        "outputs": output_reviews,
        "warnings": warnings,
        "safeJsonHash": hex::encode(Sha256::digest(serde_json::to_vec(&value).map_err(|_| CoreError::Serialization)?)),
        "scripts": request.scripts,
    });
    let review_hash = hex::encode(Sha256::digest(
        serde_json::to_vec(&review_data).map_err(|_| CoreError::Serialization)?,
    ));
    let wallet_net = i128::from(wallet_output) - i128::from(wallet_input);
    Ok(BuiltPskt {
        tx,
        entries,
        json: value.clone(),
        sighashes,
        scripts,
        review: PreparedPskt {
            profile: "generic-pskt-v2".into(),
            sender: request.sender.clone(),
            transaction_id: review_data["transactionId"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            version,
            input_count,
            output_count,
            selected_input_count: selected.len(),
            input_total_sompi: input_total,
            output_total_sompi: output_total,
            fee_sompi: fee,
            wallet_input_sompi: wallet_input,
            wallet_output_sompi: wallet_output,
            wallet_net_sompi: wallet_net,
            payload_hex,
            payload_utf8,
            inputs: input_reviews,
            outputs: output_reviews,
            warnings,
            review_hash,
        },
    })
}

fn parse_covenant(value: Option<&Value>, input_count: usize) -> Result<Option<CovenantBinding>> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    require_object(value, "covenant")?;
    let authorizing_input: u16 = u64_value(value.get("authorizingInput"))?
        .try_into()
        .map_err(|_| CoreError::InvalidRequest("covenant input exceeds u16".into()))?;
    if usize::from(authorizing_input) >= input_count {
        return Err(CoreError::InvalidRequest(
            "covenant authorizing input is out of range".into(),
        ));
    }
    let covenant_id = Hash::from_str(
        value
            .get("covenantId")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::InvalidRequest("missing covenant id".into()))?,
    )
    .map_err(|_| CoreError::InvalidRequest("invalid covenant id".into()))?;
    Ok(Some(CovenantBinding::new(authorizing_input, covenant_id)))
}

fn validate_script_request(script: &PsktScriptInput, input_count: usize) -> Result<()> {
    if script.input_index >= input_count {
        return Err(CoreError::InvalidRequest(
            "script-aware input is out of range".into(),
        ));
    }
    let _ = decode_redeem_script(&script.script_hex)?;
    if let Some(template) = &script.signature_script {
        if template.args.len() > 256 {
            return Err(CoreError::InvalidRequest(
                "signature-script template has too many arguments".into(),
            ));
        }
        let signature_count = template
            .args
            .iter()
            .filter(|argument| matches!(argument, PsktScriptArgument::Signature { .. }))
            .count();
        match template.mode {
            PsktSignatureScriptMode::WrapSignature if !template.args.is_empty() => {
                return Err(CoreError::InvalidRequest(
                    "wrap-signature does not accept explicit arguments".into(),
                ));
            }
            PsktSignatureScriptMode::SignatureFirstArgs if signature_count != 0 => {
                return Err(CoreError::InvalidRequest(
                    "signature-first-args must not include a signature argument".into(),
                ));
            }
            PsktSignatureScriptMode::OrderedArgs if signature_count != 1 => {
                return Err(CoreError::InvalidRequest(
                    "ordered-args requires exactly one signature argument".into(),
                ));
            }
            _ => {}
        }
        for argument in &template.args {
            validate_script_argument(argument)?;
        }
    }
    Ok(())
}

fn validate_script_argument(argument: &PsktScriptArgument) -> Result<()> {
    match argument {
        PsktScriptArgument::I64 { value } => {
            parse_i64_value(value)?;
        }
        PsktScriptArgument::Data { hex } => {
            let bytes = hex::decode(hex).map_err(|_| {
                CoreError::InvalidRequest("invalid signature-script data hex".into())
            })?;
            if bytes.len() > 32 * 1024 {
                return Err(CoreError::InvalidRequest(
                    "signature-script data exceeds size limit".into(),
                ));
            }
        }
        PsktScriptArgument::Signature { prefix_hex } => {
            let bytes = hex::decode(prefix_hex).map_err(|_| {
                CoreError::InvalidRequest("invalid signature prefix encoding".into())
            })?;
            if bytes.len() > 1024 {
                return Err(CoreError::InvalidRequest(
                    "signature prefix exceeds size limit".into(),
                ));
            }
        }
        PsktScriptArgument::Byte { .. } => {}
    }
    Ok(())
}

fn decode_redeem_script(raw: &str) -> Result<Vec<u8>> {
    let script = hex::decode(raw)
        .map_err(|_| CoreError::InvalidRequest("invalid covenant script encoding".into()))?;
    if script.is_empty() || script.len() > 32 * 1024 {
        return Err(CoreError::InvalidRequest(
            "invalid covenant script size".into(),
        ));
    }
    Ok(script)
}

fn parse_i64_value(value: &Value) -> Result<i64> {
    let parsed = match value {
        Value::String(raw) => raw.parse::<i64>().ok(),
        Value::Number(number) => number.as_i64(),
        _ => None,
    };
    parsed.ok_or_else(|| CoreError::InvalidRequest("invalid signed i64 script argument".into()))
}

fn raw_signature(pushed_signature: &[u8]) -> Result<&[u8]> {
    if pushed_signature.len() != 66 || pushed_signature[0] != 65 {
        return Err(CoreError::Transaction(
            "unexpected Schnorr signature encoding".into(),
        ));
    }
    Ok(&pushed_signature[1..])
}

fn assemble_p2sh_signature_script(
    script: &PsktScriptInput,
    pushed_signature: &[u8],
) -> Result<Vec<u8>> {
    let signature = raw_signature(pushed_signature)?;
    let redeem_script = decode_redeem_script(&script.script_hex)?;
    let flags = EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    };
    let mut arguments = ScriptBuilder::with_flags(flags);
    match script.signature_script.as_ref() {
        None => {
            arguments
                .add_data(signature)
                .map_err(|error| CoreError::Transaction(error.to_string()))?;
        }
        Some(template) => match template.mode {
            PsktSignatureScriptMode::WrapSignature => {
                arguments
                    .add_data(signature)
                    .map_err(|error| CoreError::Transaction(error.to_string()))?;
            }
            PsktSignatureScriptMode::SignatureFirstArgs => {
                arguments
                    .add_data(signature)
                    .map_err(|error| CoreError::Transaction(error.to_string()))?;
                for argument in &template.args {
                    append_script_argument(&mut arguments, argument, signature)?;
                }
            }
            PsktSignatureScriptMode::OrderedArgs => {
                for argument in &template.args {
                    append_script_argument(&mut arguments, argument, signature)?;
                }
            }
        },
    }
    pay_to_script_hash_signature_script_with_flags(redeem_script, arguments.drain(), flags)
        .map_err(|error| CoreError::Transaction(error.to_string()))
}

fn append_script_argument(
    builder: &mut ScriptBuilder,
    argument: &PsktScriptArgument,
    signature: &[u8],
) -> Result<()> {
    match argument {
        PsktScriptArgument::I64 { value } => {
            builder
                .add_i64(parse_i64_value(value)?)
                .map_err(|error| CoreError::Transaction(error.to_string()))?;
        }
        PsktScriptArgument::Data { hex } => {
            let bytes = hex::decode(hex).map_err(|_| {
                CoreError::InvalidRequest("invalid signature-script data hex".into())
            })?;
            builder
                .add_data(&bytes)
                .map_err(|error| CoreError::Transaction(error.to_string()))?;
        }
        PsktScriptArgument::Byte { value } => {
            builder
                .add_data_with_push_opcode(&[*value])
                .map_err(|error| CoreError::Transaction(error.to_string()))?;
        }
        PsktScriptArgument::Signature { prefix_hex } => {
            let mut bytes = hex::decode(prefix_hex).map_err(|_| {
                CoreError::InvalidRequest("invalid signature prefix encoding".into())
            })?;
            bytes.extend_from_slice(signature);
            builder
                .add_data(&bytes)
                .map_err(|error| CoreError::Transaction(error.to_string()))?;
        }
    }
    Ok(())
}

fn signature_script_mode_label(mode: &PsktSignatureScriptMode) -> &'static str {
    match mode {
        PsktSignatureScriptMode::WrapSignature => "wrap-signature",
        PsktSignatureScriptMode::SignatureFirstArgs => "signature-first-args",
        PsktSignatureScriptMode::OrderedArgs => "ordered-args",
    }
}

fn require_object(value: &Value, label: &str) -> Result<()> {
    value
        .as_object()
        .ok_or_else(|| CoreError::InvalidRequest(format!("{label} must be an object")))?;
    Ok(())
}

fn script_public_key(raw: &str) -> Result<ScriptPublicKey> {
    let bytes =
        hex::decode(raw).map_err(|_| CoreError::UntrustedUtxo("invalid script encoding".into()))?;
    if bytes.len() < 2 {
        return Err(CoreError::UntrustedUtxo("short script encoding".into()));
    }
    Ok(ScriptPublicKey::new(
        u16::from_be_bytes([bytes[0], bytes[1]]),
        bytes[2..].to_vec().into(),
    ))
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

fn sighash_label(value: SigHashType) -> String {
    let base = if value.is_sighash_all() {
        "ALL"
    } else if value.is_sighash_none() {
        "NONE"
    } else {
        "SINGLE"
    };
    if value.is_sighash_anyone_can_pay() {
        format!("{base}|ANYONECANPAY")
    } else {
        base.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "private:0000000000000000000000000000000000000000000000000000000000000001";

    fn script_json(script: &ScriptPublicKey) -> String {
        let mut bytes = script.version().to_be_bytes().to_vec();
        bytes.extend_from_slice(script.script());
        hex::encode(bytes)
    }

    fn request() -> PsktRequest {
        let sender = derive_address(SECRET).unwrap();
        let script = pay_to_address_script(&sender);
        let safe = json!({
            "version": 0,
            "inputs": [{
                "transactionId": "11".repeat(32),
                "index": 0,
                "sequence": "0",
                "sigOpCount": 1,
                "signatureScript": "",
                "utxo": {
                    "amount": "200000000",
                    "scriptPublicKey": script_json(&script),
                    "blockDaaScore": "100",
                    "isCoinbase": false
                }
            }],
            "outputs": [{
                "value": "199000000",
                "scriptPublicKey": script_json(&script)
            }],
            "subnetworkId": SUBNETWORK_ID_NATIVE.to_string(),
            "lockTime": "0",
            "gas": "0",
            "storageMass": "0",
            "payload": ""
        });
        PsktRequest {
            sender: sender.to_string(),
            tx_json_string: safe.to_string(),
            sign_inputs: vec![PsktSignInput {
                index: 0,
                sighash_type: 1,
            }],
            scripts: vec![],
        }
    }

    #[test]
    fn signs_reviewed_safejson_and_binds_review() {
        let request = request();
        let prepared = prepare_pskt(&request).unwrap();
        assert_eq!(prepared.fee_sompi, 1_000_000);
        assert_eq!(prepared.wallet_net_sompi, -1_000_000);
        assert!(prepared.warnings.is_empty());
        assert!(matches!(
            sign_pskt(SECRET, &request, "wrong"),
            Err(CoreError::ReviewMismatch)
        ));
        let signed = sign_pskt(SECRET, &request, &prepared.review_hash).unwrap();
        let value: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
        assert!(!value["inputs"][0]["signatureScript"]
            .as_str()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn rejects_duplicate_outpoints_and_presigned_selected_input() {
        let mut duplicate_request = request();
        let mut value: Value = serde_json::from_str(&duplicate_request.tx_json_string).unwrap();
        let duplicate = value["inputs"][0].clone();
        value["inputs"].as_array_mut().unwrap().push(duplicate);
        duplicate_request.sign_inputs = vec![
            PsktSignInput {
                index: 0,
                sighash_type: 1,
            },
            PsktSignInput {
                index: 1,
                sighash_type: 1,
            },
        ];
        duplicate_request.tx_json_string = value.to_string();
        assert!(prepare_pskt(&duplicate_request).is_err());

        let mut request = request();
        let mut value: Value = serde_json::from_str(&request.tx_json_string).unwrap();
        value["inputs"][0]["signatureScript"] = json!("01");
        request.tx_json_string = value.to_string();
        assert!(prepare_pskt(&request).is_err());
    }

    #[test]
    fn warns_for_partial_and_mutable_sighash() {
        let mut request = request();
        let mut value: Value = serde_json::from_str(&request.tx_json_string).unwrap();
        let mut second = value["inputs"][0].clone();
        second["transactionId"] = json!("22".repeat(32));
        second["signatureScript"] = json!("01");
        value["inputs"].as_array_mut().unwrap().push(second);
        request.sign_inputs[0].sighash_type = 129;
        request.tx_json_string = value.to_string();
        let prepared = prepare_pskt(&request).unwrap();
        assert!(prepared
            .warnings
            .iter()
            .any(|item| item.contains("partial")));
        assert!(prepared
            .warnings
            .iter()
            .any(|item| item.contains("ANYONECANPAY")));
    }

    #[test]
    fn preserves_unknown_safejson_fields_while_signing() {
        let mut request = request();
        let mut value: Value = serde_json::from_str(&request.tx_json_string).unwrap();
        value["marketplaceMetadata"] = json!({"listing": "kept"});
        value["inputs"][0]["adapterField"] = json!({"safe": true});
        value["inputs"][0]["utxo"]["indexerHint"] = json!("kept");
        value["outputs"][0]["assetMetadata"] = json!([1, 2, 3]);
        request.tx_json_string = value.to_string();
        let review = prepare_pskt(&request).unwrap();
        let signed = sign_pskt(SECRET, &request, &review.review_hash).unwrap();
        let result: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
        assert_eq!(result["marketplaceMetadata"], json!({"listing": "kept"}));
        assert_eq!(result["inputs"][0]["adapterField"], json!({"safe": true}));
        assert_eq!(result["inputs"][0]["utxo"]["indexerHint"], json!("kept"));
        assert_eq!(result["outputs"][0]["assetMetadata"], json!([1, 2, 3]));
    }

    #[test]
    fn assembles_script_templates_and_supports_script_only_selection() {
        let sender = derive_address(SECRET).unwrap();
        let sender_script = pay_to_address_script(&sender);
        let redeem_script = ScriptBuilder::with_flags(EngineFlags {
            covenants_enabled: true,
            ..Default::default()
        })
        .add_data(sender.payload.as_slice())
        .unwrap()
        .drain();
        let p2sh = pay_to_script_hash_script(&redeem_script);
        let safe = json!({
            "version": 0,
            "inputs": [{
                "transactionId": "33".repeat(32),
                "index": 0,
                "sequence": "0",
                "sigOpCount": 1,
                "signatureScript": "",
                "utxo": {
                    "amount": "200000000",
                    "scriptPublicKey": script_json(&p2sh),
                    "blockDaaScore": "100",
                    "isCoinbase": false
                }
            }],
            "outputs": [{
                "value": "199000000",
                "scriptPublicKey": script_json(&sender_script)
            }],
            "subnetworkId": SUBNETWORK_ID_NATIVE.to_string(),
            "lockTime": "0",
            "gas": "0",
            "storageMass": "0",
            "payload": ""
        });
        let request = PsktRequest {
            sender: sender.to_string(),
            tx_json_string: safe.to_string(),
            sign_inputs: vec![],
            scripts: vec![PsktScriptInput {
                input_index: 0,
                script_hex: hex::encode(&redeem_script),
                sign_type: Some(132),
                signature_script: Some(PsktSignatureScriptTemplate {
                    mode: PsktSignatureScriptMode::OrderedArgs,
                    args: vec![
                        PsktScriptArgument::I64 { value: json!(7) },
                        PsktScriptArgument::Byte { value: 255 },
                        PsktScriptArgument::Signature {
                            prefix_hex: "aa".into(),
                        },
                    ],
                }),
            }],
        };
        let prepared = prepare_pskt(&request).unwrap();
        assert_eq!(prepared.selected_input_count, 1);
        assert_eq!(prepared.inputs[0].sighash_type, Some(132));
        assert_eq!(
            prepared.inputs[0].signature_script_mode.as_deref(),
            Some("ordered-args")
        );
        let signed = sign_pskt(SECRET, &request, &prepared.review_hash).unwrap();
        let result: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
        let signature_script =
            hex::decode(result["inputs"][0]["signatureScript"].as_str().unwrap()).unwrap();
        assert!(signature_script.ends_with(&redeem_script));
        assert!(signature_script.windows(2).any(|bytes| bytes == [66, 0xaa]));
    }

    #[test]
    fn assembles_every_kaspacom_signature_template_and_argument_type() {
        let sender = derive_address(SECRET).unwrap();
        let sender_script = pay_to_address_script(&sender);
        let redeem_script = ScriptBuilder::with_flags(EngineFlags {
            covenants_enabled: true,
            ..Default::default()
        })
        .add_data(sender.payload.as_slice())
        .unwrap()
        .drain();
        let p2sh = pay_to_script_hash_script(&redeem_script);
        let safe = json!({
            "version": 0,
            "inputs": [{
                "transactionId": "55".repeat(32),
                "index": 0,
                "sequence": "0",
                "sigOpCount": 1,
                "signatureScript": "",
                "utxo": {
                    "amount": "200000000",
                    "scriptPublicKey": script_json(&p2sh),
                    "blockDaaScore": "100",
                    "isCoinbase": false,
                    "marketplaceInputMetadata": {"preserve": true}
                }
            }],
            "outputs": [{
                "value": "199000000",
                "scriptPublicKey": script_json(&sender_script),
                "covenant": {
                    "authorizingInput": 0,
                    "covenantId": "66".repeat(32)
                },
                "marketplaceOutputMetadata": {"preserve": true}
            }],
            "subnetworkId": SUBNETWORK_ID_NATIVE.to_string(),
            "lockTime": "0",
            "gas": "0",
            "storageMass": "0",
            "payload": "",
            "marketplaceMetadata": {"preserve": true}
        });
        let templates = vec![
            PsktSignatureScriptTemplate {
                mode: PsktSignatureScriptMode::WrapSignature,
                args: vec![],
            },
            PsktSignatureScriptTemplate {
                mode: PsktSignatureScriptMode::SignatureFirstArgs,
                args: vec![
                    PsktScriptArgument::I64 { value: json!(-7) },
                    PsktScriptArgument::Data { hex: "abcd".into() },
                    PsktScriptArgument::Byte { value: 255 },
                ],
            },
            PsktSignatureScriptTemplate {
                mode: PsktSignatureScriptMode::OrderedArgs,
                args: vec![
                    PsktScriptArgument::Data { hex: "cafe".into() },
                    PsktScriptArgument::Signature {
                        prefix_hex: "01".into(),
                    },
                    PsktScriptArgument::I64 { value: json!(9) },
                    PsktScriptArgument::Byte { value: 0 },
                ],
            },
        ];
        for template in templates {
            let request = PsktRequest {
                sender: sender.to_string(),
                tx_json_string: safe.to_string(),
                sign_inputs: vec![PsktSignInput {
                    index: 0,
                    sighash_type: 132,
                }],
                scripts: vec![PsktScriptInput {
                    input_index: 0,
                    script_hex: hex::encode(&redeem_script),
                    sign_type: None,
                    signature_script: Some(template),
                }],
            };
            let prepared = prepare_pskt(&request).unwrap();
            assert_eq!(prepared.inputs[0].sighash_type, Some(132));
            let signed = sign_pskt(SECRET, &request, &prepared.review_hash).unwrap();
            let result: Value = serde_json::from_str(&signed.signed_tx_json).unwrap();
            let signature_script =
                hex::decode(result["inputs"][0]["signatureScript"].as_str().unwrap()).unwrap();
            assert!(signature_script.ends_with(&redeem_script));
            assert_eq!(result["marketplaceMetadata"], json!({"preserve": true}));
            assert_eq!(
                result["inputs"][0]["utxo"]["marketplaceInputMetadata"],
                json!({"preserve": true})
            );
            assert_eq!(
                result["outputs"][0]["marketplaceOutputMetadata"],
                json!({"preserve": true})
            );
            assert_eq!(
                result["outputs"][0]["covenant"],
                safe["outputs"][0]["covenant"]
            );
        }
    }

    #[test]
    fn rejects_script_that_does_not_match_p2sh_utxo() {
        let mut request = request();
        request.scripts = vec![PsktScriptInput {
            input_index: 0,
            script_hex: "51".into(),
            sign_type: Some(1),
            signature_script: None,
        }];
        assert!(matches!(
            prepare_pskt(&request),
            Err(CoreError::UntrustedUtxo(_))
        ));
    }
}
