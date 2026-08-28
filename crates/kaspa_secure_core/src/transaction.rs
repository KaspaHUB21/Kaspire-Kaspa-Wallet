use crate::{derive_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix};
use kaspa_consensus_core::{
    config::params::{MAINNET_PARAMS, TESTNET_PARAMS},
    mass::{ContextualMasses, Mass, MassCalculator},
    sign::sign_with_multiple_v2,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        SignableTransaction, Transaction, TransactionInput, TransactionOutpoint, TransactionOutput,
        UtxoEntry,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::str::FromStr;

const MAX_INPUTS: usize = 80;
const DUST_LIMIT_SOMPI: u64 = 10_000;
const SIGNATURE_SCRIPT_SIZE: usize = 66;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendRequest {
    pub sender: String,
    pub recipient: String,
    pub amount_sompi: u64,
    pub fee_rate: f64,
    pub utxos_json: String,
    #[serde(default)]
    pub send_all: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedTransaction {
    pub sender: String,
    pub recipient: String,
    pub amount_sompi: u64,
    pub total_input_sompi: u64,
    pub change_sompi: u64,
    pub fee_sompi: u64,
    pub mass: u64,
    pub input_count: usize,
    pub output_count: usize,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedTransaction {
    pub transaction_id: String,
    pub fee_sompi: u64,
    pub mass: u64,
    pub submit_json: String,
    pub review_hash: String,
}

#[derive(Clone)]
pub(crate) struct Spendable {
    pub(crate) outpoint: TransactionOutpoint,
    pub(crate) entry: UtxoEntry,
}

pub(crate) struct Built {
    pub(crate) signable: SignableTransaction,
    pub(crate) review: PreparedTransaction,
}

pub fn prepare_transaction(request: &SendRequest) -> Result<PreparedTransaction> {
    Ok(build(request)?.review)
}

pub fn sign_transaction(
    phrase: &str,
    request: &SendRequest,
    approved_review_hash: &str,
) -> Result<SignedTransaction> {
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let mut derived = derive_address(phrase)?;
    derived.prefix = sender.prefix;
    let derived = derived.to_string();
    if derived != request.sender {
        return Err(CoreError::InvalidRequest(
            "seed does not control sender".into(),
        ));
    }
    let built = build(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = derive_key(phrase)?;
    let signed = sign_with_multiple_v2(built.signable, &[*key])
        .fully_signed()
        .map_err(|e| CoreError::Transaction(e.to_string()))?;
    let txid = signed.tx.id().to_string();
    let submit_json = submit_json(&signed.tx)?;
    Ok(SignedTransaction {
        transaction_id: txid,
        fee_sompi: built.review.fee_sompi,
        mass: built.review.mass,
        submit_json,
        review_hash: built.review.review_hash,
    })
}

pub(crate) fn build(request: &SendRequest) -> Result<Built> {
    if (!request.send_all && request.amount_sompi == 0)
        || !request.fee_rate.is_finite()
        || request.fee_rate < 1.0
        || request.fee_rate > 1000.0
    {
        return Err(CoreError::InvalidRequest(
            "amount or fee rate out of range".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let recipient =
        Address::try_from(request.recipient.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if !matches!(sender.prefix, Prefix::Mainnet | Prefix::Testnet)
        || recipient.prefix != sender.prefix
    {
        return Err(CoreError::InvalidAddress);
    }
    let params = if sender.prefix == Prefix::Testnet {
        &TESTNET_PARAMS
    } else {
        &MAINNET_PARAMS
    };
    let mut available = parse_utxos(&request.utxos_json, &sender)?;
    available.sort_by(|a, b| b.entry.amount.cmp(&a.entry.amount));
    if request.send_all {
        return build_send_all(request, &sender, &recipient, available);
    }
    let mut selected = Vec::new();
    let mut total_input = 0u64;
    let mut cursor = 0usize;
    let mut fee = 0u64;
    let mass_calculator = MassCalculator::new_with_consensus_params(params);

    let (unsigned_tx, mass, change) = loop {
        while total_input <= request.amount_sompi.saturating_add(fee) {
            let next = available
                .get(cursor)
                .cloned()
                .ok_or(CoreError::InsufficientFunds)?;
            cursor += 1;
            if selected.len() >= MAX_INPUTS {
                return Err(CoreError::InvalidRequest(
                    "more than 80 inputs required; consolidate first".into(),
                ));
            }
            total_input = total_input
                .checked_add(next.entry.amount)
                .ok_or_else(|| CoreError::InvalidRequest("input overflow".into()))?;
            selected.push(next);
        }

        let provisional_change = total_input - request.amount_sompi - fee;
        let change = if provisional_change >= DUST_LIMIT_SOMPI {
            provisional_change
        } else {
            0
        };
        let actual_fee = total_input - request.amount_sompi - change;
        let tx = make_transaction(
            &selected,
            &recipient,
            &sender,
            request.amount_sompi,
            change,
            true,
        );
        let entries = selected
            .iter()
            .map(|item| item.entry.clone())
            .collect::<Vec<_>>();
        let populated = SignableTransaction::with_entries(tx.clone(), entries);
        let non_contextual = mass_calculator.calc_non_contextual_masses(&tx);
        let verifiable = populated.as_verifiable();
        let contextual = mass_calculator
            .calc_contextual_masses(&verifiable)
            .ok_or_else(|| CoreError::Transaction("storage mass cannot be calculated".into()))?;
        let mass = Mass::new(
            non_contextual,
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&params.mempool_block_mass_cofactors().after());
        let required_fee = (request.fee_rate * mass as f64).ceil() as u64;
        if actual_fee >= required_fee {
            let unsigned = make_transaction(
                &selected,
                &recipient,
                &sender,
                request.amount_sompi,
                change,
                false,
            );
            break (unsigned, mass, change);
        }
        fee = required_fee;
    };

    let mut unsigned_tx = unsigned_tx;
    unsigned_tx.set_storage_mass(mass);
    unsigned_tx.finalize();
    let entries = selected
        .iter()
        .map(|item| item.entry.clone())
        .collect::<Vec<_>>();
    let signable = SignableTransaction::with_entries(unsigned_tx.clone(), entries);
    let final_fee = total_input - request.amount_sompi - change;
    let review_without_hash = json!({
        "network": if sender.prefix == Prefix::Testnet { "kaspa:testnet-10" } else { "kaspa:mainnet" },
        "version": unsigned_tx.version,
        "sender": sender.to_string(),
        "recipient": recipient.to_string(),
        "amountSompi": request.amount_sompi,
        "totalInputSompi": total_input,
        "changeSompi": change,
        "feeSompi": final_fee,
        "mass": mass,
        "inputs": unsigned_tx.inputs.iter().map(|i| json!({"transactionId": i.previous_outpoint.transaction_id.to_string(), "index": i.previous_outpoint.index})).collect::<Vec<_>>(),
        "outputs": unsigned_tx.outputs.iter().map(|o| json!({"amountSompi": o.value, "scriptPublicKey": hex::encode(o.script_public_key.script())})).collect::<Vec<_>>(),
        "payload": "",
    });
    let encoded = serde_json::to_vec(&review_without_hash).map_err(|_| CoreError::Serialization)?;
    let review_hash = hex::encode(Sha256::digest(encoded));
    let review = PreparedTransaction {
        sender: sender.to_string(),
        recipient: recipient.to_string(),
        amount_sompi: request.amount_sompi,
        total_input_sompi: total_input,
        change_sompi: change,
        fee_sompi: final_fee,
        mass,
        input_count: unsigned_tx.inputs.len(),
        output_count: unsigned_tx.outputs.len(),
        review_hash,
    };
    Ok(Built { signable, review })
}

fn build_send_all(
    request: &SendRequest,
    sender: &Address,
    recipient: &Address,
    available: Vec<Spendable>,
) -> Result<Built> {
    if available.is_empty() || available.len() > MAX_INPUTS {
        return Err(CoreError::InvalidRequest(
            "send max requires between 1 and 80 spendable inputs".into(),
        ));
    }
    let total_input = available.iter().try_fold(0u64, |total, item| {
        total
            .checked_add(item.entry.amount)
            .ok_or_else(|| CoreError::InvalidRequest("input overflow".into()))
    })?;
    let params = if sender.prefix == Prefix::Testnet {
        &TESTNET_PARAMS
    } else {
        &MAINNET_PARAMS
    };
    let mass_calculator = MassCalculator::new_with_consensus_params(params);
    let mut fee = 0u64;
    let (mut unsigned_tx, mass, amount) = loop {
        let amount = total_input
            .checked_sub(fee)
            .ok_or(CoreError::InsufficientFunds)?;
        if amount < DUST_LIMIT_SOMPI {
            return Err(CoreError::InsufficientFunds);
        }
        let estimated = make_transaction(&available, recipient, sender, amount, 0, true);
        let entries = available
            .iter()
            .map(|item| item.entry.clone())
            .collect::<Vec<_>>();
        let populated = SignableTransaction::with_entries(estimated.clone(), entries);
        let non_contextual = mass_calculator.calc_non_contextual_masses(&estimated);
        let contextual = mass_calculator
            .calc_contextual_masses(&populated.as_verifiable())
            .ok_or_else(|| CoreError::Transaction("storage mass cannot be calculated".into()))?;
        let mass = Mass::new(
            non_contextual,
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&params.mempool_block_mass_cofactors().after());
        let required_fee = (request.fee_rate * mass as f64).ceil() as u64;
        if fee >= required_fee {
            break (
                make_transaction(&available, recipient, sender, amount, 0, false),
                mass,
                amount,
            );
        }
        fee = required_fee;
    };
    unsigned_tx.set_storage_mass(mass);
    unsigned_tx.finalize();
    let entries = available
        .iter()
        .map(|item| item.entry.clone())
        .collect::<Vec<_>>();
    let signable = SignableTransaction::with_entries(unsigned_tx.clone(), entries);
    let review_without_hash = json!({
        "network": if sender.prefix == Prefix::Testnet { "kaspa:testnet-10" } else { "kaspa:mainnet" }, "version": unsigned_tx.version,
        "sender": sender.to_string(), "recipient": recipient.to_string(),
        "amountSompi": amount, "totalInputSompi": total_input,
        "changeSompi": 0, "feeSompi": fee, "mass": mass,
        "inputs": unsigned_tx.inputs.iter().map(|i| json!({"transactionId": i.previous_outpoint.transaction_id.to_string(), "index": i.previous_outpoint.index})).collect::<Vec<_>>(),
        "outputs": unsigned_tx.outputs.iter().map(|o| json!({"amountSompi": o.value, "scriptPublicKey": hex::encode(o.script_public_key.script())})).collect::<Vec<_>>(),
        "payload": "", "sendAll": true,
    });
    let encoded = serde_json::to_vec(&review_without_hash).map_err(|_| CoreError::Serialization)?;
    let review_hash = hex::encode(Sha256::digest(encoded));
    let review = PreparedTransaction {
        sender: sender.to_string(),
        recipient: recipient.to_string(),
        amount_sompi: amount,
        total_input_sompi: total_input,
        change_sompi: 0,
        fee_sompi: fee,
        mass,
        input_count: unsigned_tx.inputs.len(),
        output_count: unsigned_tx.outputs.len(),
        review_hash,
    };
    Ok(Built { signable, review })
}

fn make_transaction(
    selected: &[Spendable],
    recipient: &Address,
    sender: &Address,
    amount: u64,
    change: u64,
    estimated_signed: bool,
) -> Transaction {
    let signature = if estimated_signed {
        vec![0; SIGNATURE_SCRIPT_SIZE]
    } else {
        vec![]
    };
    let inputs = selected
        .iter()
        .map(|item| TransactionInput::new(item.outpoint, signature.clone(), 0, 1))
        .collect();
    let mut outputs = vec![TransactionOutput::new(
        amount,
        kaspa_txscript::pay_to_address_script(recipient),
    )];
    if change > 0 {
        outputs.push(TransactionOutput::new(
            change,
            kaspa_txscript::pay_to_address_script(sender),
        ));
    }
    Transaction::new(0, inputs, outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![])
}

pub(crate) fn parse_utxos(raw: &str, sender: &Address) -> Result<Vec<Spendable>> {
    let value: Value =
        serde_json::from_str(raw).map_err(|_| CoreError::UntrustedUtxo("invalid JSON".into()))?;
    let list = value
        .as_array()
        .ok_or_else(|| CoreError::UntrustedUtxo("expected array".into()))?;
    if list.len() > 250 {
        return Err(CoreError::InvalidRequest(
            "UTXO set exceeds mobile safety limit".into(),
        ));
    }
    let expected_script = kaspa_txscript::pay_to_address_script(sender);
    let mut result = Vec::with_capacity(list.len());
    let mut seen = HashSet::with_capacity(list.len());
    for item in list {
        let address = item
            .get("address")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing address".into()))?;
        if address != sender.to_string() {
            return Err(CoreError::UntrustedUtxo("address mismatch".into()));
        }
        let outpoint = item
            .get("outpoint")
            .ok_or_else(|| CoreError::UntrustedUtxo("missing outpoint".into()))?;
        let txid = outpoint
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing transaction id".into()))?;
        let transaction_id = kaspa_consensus_core::tx::TransactionId::from_str(txid)
            .map_err(|_| CoreError::UntrustedUtxo("invalid transaction id".into()))?;
        let index = u32::try_from(value_u64(outpoint.get("index"))?)
            .map_err(|_| CoreError::UntrustedUtxo("outpoint index out of range".into()))?;
        if !seen.insert((transaction_id, index)) {
            return Err(CoreError::UntrustedUtxo("duplicate outpoint".into()));
        }
        let entry = item
            .get("utxoEntry")
            .ok_or_else(|| CoreError::UntrustedUtxo("missing entry".into()))?;
        let amount = value_u64(entry.get("amount"))?;
        if amount == 0 {
            return Err(CoreError::UntrustedUtxo("zero-value UTXO".into()));
        }
        let block_daa_score = value_u64(entry.get("blockDaaScore"))?;
        let is_coinbase = entry
            .get("isCoinbase")
            .and_then(Value::as_bool)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing coinbase flag".into()))?;
        if is_coinbase {
            continue;
        }
        let script_hex = entry
            .get("scriptPublicKey")
            .and_then(|v| v.get("scriptPublicKey"))
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::UntrustedUtxo("missing script".into()))?;
        let script = hex::decode(script_hex)
            .map_err(|_| CoreError::UntrustedUtxo("invalid script".into()))?;
        if script.as_slice() != expected_script.script() {
            return Err(CoreError::UntrustedUtxo(
                "script does not pay sender".into(),
            ));
        }
        result.push(Spendable {
            outpoint: TransactionOutpoint::new(transaction_id, index),
            entry: UtxoEntry::new(
                amount,
                expected_script.clone(),
                block_daa_score,
                false,
                None,
            ),
        });
    }
    Ok(result)
}

fn value_u64(value: Option<&Value>) -> Result<u64> {
    match value {
        Some(Value::String(s)) => s
            .parse()
            .map_err(|_| CoreError::UntrustedUtxo("invalid integer".into())),
        Some(Value::Number(n)) => n
            .as_u64()
            .ok_or_else(|| CoreError::UntrustedUtxo("invalid integer".into())),
        _ => Err(CoreError::UntrustedUtxo("missing integer".into())),
    }
}

pub(crate) fn submit_json(tx: &Transaction) -> Result<String> {
    if tx.version != 0
        || !tx.payload.is_empty()
        || tx
            .outputs
            .iter()
            .any(|o: &TransactionOutput| o.covenant.is_some())
    {
        return Err(CoreError::InvalidRequest(
            "REST submit supports only standard v0 payments in this release".into(),
        ));
    }
    let transaction = json!({
        "version": tx.version,
        "inputs": tx.inputs.iter().map(|input: &TransactionInput| json!({
            "previousOutpoint": {"transactionId": input.previous_outpoint.transaction_id.to_string(), "index": input.previous_outpoint.index},
            "signatureScript": hex::encode(&input.signature_script),
            "sequence": input.sequence,
            "sigOpCount": input.compute_commit.sig_op_count().unwrap_or_default(),
        })).collect::<Vec<_>>(),
        "outputs": tx.outputs.iter().map(|output| json!({
            "amount": output.value,
            "scriptPublicKey": {"version": output.script_public_key.version(), "scriptPublicKey": hex::encode(output.script_public_key.script())},
        })).collect::<Vec<_>>(),
        "lockTime": tx.lock_time,
        "subnetworkId": tx.subnetwork_id.to_string(),
    });
    serde_json::to_string(&json!({"transaction": transaction, "allowOrphan": false}))
        .map_err(|_| CoreError::Serialization)
}

#[cfg(test)]
mod adversarial_tests {
    use super::*;
    use kaspa_addresses::Address;

    const ADDRESS: &str = "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";

    #[test]
    fn malformed_utxo_corpus_fails_closed_without_panicking() {
        let sender = Address::try_from(ADDRESS).unwrap();
        let corpus = [
            "",
            "null",
            "{}",
            "[null]",
            "[{}]",
            r#"[{"address":"kaspa:qattacker","outpoint":{},"utxoEntry":{}}]"#,
            r#"[{"address":"kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh","outpoint":{"transactionId":"../evil","index":-1},"utxoEntry":{"amount":"-1"}}]"#,
        ];
        for raw in corpus {
            assert!(parse_utxos(raw, &sender).is_err(), "accepted: {raw}");
        }
    }

    #[test]
    fn duplicate_outpoints_and_oversized_indices_are_rejected() {
        let sender = Address::try_from(ADDRESS).unwrap();
        let script = hex::encode(kaspa_txscript::pay_to_address_script(&sender).script());
        let item = json!({
            "address": ADDRESS,
            "outpoint": {"transactionId": "11".repeat(32), "index": 0},
            "utxoEntry": {
                "amount": "100000000",
                "blockDaaScore": "1",
                "isCoinbase": false,
                "scriptPublicKey": {"scriptPublicKey": script.clone()}
            }
        });
        assert!(parse_utxos(&json!([item.clone(), item]).to_string(), &sender).is_err());

        let oversized = json!([{
            "address": ADDRESS,
            "outpoint": {"transactionId": "22".repeat(32), "index": u64::from(u32::MAX) + 1},
            "utxoEntry": {
                "amount": "100000000",
                "blockDaaScore": "1",
                "isCoinbase": false,
                "scriptPublicKey": {"scriptPublicKey": script}
            }
        }]);
        assert!(parse_utxos(&oversized.to_string(), &sender).is_err());
    }
}
