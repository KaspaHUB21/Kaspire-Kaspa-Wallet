use crate::{derive_address, derive_key, CoreError, Result};
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
use std::{collections::HashSet, str::FromStr};

const MAX_PSKT_BYTES: usize = 512 * 1024;
const MAX_INPUTS: usize = 256;
const MAX_OUTPUTS: usize = 256;
const MAX_PAYLOAD_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktSignInput {
    pub index: usize,
    #[serde(default = "default_sighash")]
    pub sighash_type: u8,
}

fn default_sighash() -> u8 {
    SIG_HASH_ALL.to_u8()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PsktRequest {
    pub sender: String,
    pub tx_json_string: String,
    pub sign_inputs: Vec<PsktSignInput>,
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
    pub transaction_id: String,
    pub signed_input_indexes: Vec<usize>,
    pub review_hash: String,
}

struct BuiltPskt {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    json: Value,
    sighashes: Vec<(usize, SigHashType)>,
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
    if derive_address(secret)?.to_string() != request.sender {
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
        let signature = sign_input(&populated.as_verifiable(), *index, &*key, *sighash);
        built.tx.inputs[*index].signature_script = signature.clone();
        built.json["inputs"][*index]["signatureScript"] = Value::String(hex::encode(signature));
    }
    built.tx.finalize();
    built.json["id"] = Value::String(built.tx.id().to_string());
    Ok(SignedPskt {
        signed_tx_json: serde_json::to_string(&built.json).map_err(|_| CoreError::Serialization)?,
        transaction_id: built.tx.id().to_string(),
        signed_input_indexes: built.sighashes.iter().map(|(index, _)| *index).collect(),
        review_hash: built.review.review_hash,
    })
}

fn build_pskt(request: &PsktRequest) -> Result<BuiltPskt> {
    if request.tx_json_string.is_empty() || request.tx_json_string.len() > MAX_PSKT_BYTES {
        return Err(CoreError::InvalidRequest("PSKT exceeds size limit".into()));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let sender_script = pay_to_address_script(&sender);
    let mut value: Value = serde_json::from_str(&request.tx_json_string)
        .map_err(|_| CoreError::InvalidRequest("invalid transaction SafeJSON".into()))?;
    let object = value
        .as_object_mut()
        .ok_or_else(|| CoreError::InvalidRequest("transaction must be an object".into()))?;
    let allowed = [
        "id",
        "version",
        "inputs",
        "outputs",
        "subnetworkId",
        "lockTime",
        "gas",
        "storageMass",
        "mass",
        "payload",
    ];
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(CoreError::InvalidRequest(
            "unknown transaction SafeJSON field".into(),
        ));
    }
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
    if request.sign_inputs.is_empty() || request.sign_inputs.len() > inputs_json.len() {
        return Err(CoreError::InvalidRequest(
            "invalid selected input count".into(),
        ));
    }
    let mut selected = HashSet::new();
    let mut sighashes = Vec::with_capacity(request.sign_inputs.len());
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
        sighashes.push((selection.index, sighash));
    }
    sighashes.sort_by_key(|(index, _)| *index);

    let mut seen_outpoints = HashSet::new();
    let mut inputs = Vec::with_capacity(inputs_json.len());
    let mut entries = Vec::with_capacity(inputs_json.len());
    let mut input_reviews = Vec::with_capacity(inputs_json.len());
    let mut input_total = 0u64;
    let mut wallet_input = 0u64;
    let mut warnings = Vec::new();
    for (index, item) in inputs_json.iter().enumerate() {
        reject_unknown_fields(
            item,
            &[
                "transactionId",
                "index",
                "sequence",
                "sigOpCount",
                "computeBudget",
                "signatureScript",
                "utxo",
            ],
            "input",
        )?;
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
        reject_unknown_fields(
            utxo,
            &[
                "address",
                "amount",
                "scriptPublicKey",
                "blockDaaScore",
                "isCoinbase",
                "covenantId",
            ],
            "embedded UTXO",
        )?;
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
        });
        inputs.push(input);
        entries.push(entry);
    }

    let mut outputs = Vec::with_capacity(outputs_json.len());
    let mut output_reviews = Vec::with_capacity(outputs_json.len());
    let mut output_total = 0u64;
    let mut wallet_output = 0u64;
    for (index, item) in outputs_json.iter().enumerate() {
        reject_unknown_fields(item, &["value", "scriptPublicKey", "covenant"], "output")?;
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
        "profile": "generic-pskt-v1",
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
        review: PreparedPskt {
            profile: "generic-pskt-v1".into(),
            sender: request.sender.clone(),
            transaction_id: review_data["transactionId"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            version,
            input_count,
            output_count,
            selected_input_count: request.sign_inputs.len(),
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
    reject_unknown_fields(value, &["authorizingInput", "covenantId"], "covenant")?;
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

fn reject_unknown_fields(value: &Value, allowed: &[&str], label: &str) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| CoreError::InvalidRequest(format!("{label} must be an object")))?;
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(CoreError::InvalidRequest(format!(
            "unknown {label} SafeJSON field"
        )));
    }
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
}
