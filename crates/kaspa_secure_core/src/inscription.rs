use crate::{derive_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    hashing::sighash_type::SIG_HASH_ALL,
    mass::{ContextualMasses, Mass, MassCalculator},
    sign::sign_input,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        SignableTransaction, Transaction, TransactionInput, TransactionOutpoint, TransactionOutput,
        UtxoEntry,
    },
};
use kaspa_txscript::{
    extract_script_pub_key_address,
    opcodes::codes::{OpCheckSig, OpCheckSigECDSA, OpEndIf, OpFalse, OpIf},
    pay_to_address_script, pay_to_script_hash_script, pay_to_script_hash_signature_script,
    script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::str::FromStr;

const COMMIT_AMOUNT_SOMPI: u64 = 30_000_000;
const DUST_LIMIT_SOMPI: u64 = 10_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InscriptionRequest {
    pub kind: String,
    pub sender: String,
    pub recipient: String,
    #[serde(default)]
    pub ticker: String,
    #[serde(default)]
    pub amount: String,
    #[serde(default)]
    pub token_id: String,
    #[serde(default)]
    pub asset_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InscriptionPlan {
    pub kind: String,
    pub commit_address: String,
    pub commit_amount_sompi: u64,
    pub namespace: String,
    pub payload_json: String,
    pub redeem_script_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RevealRequest {
    pub operation: InscriptionRequest,
    pub commit_transaction_id: String,
    pub commit_utxos_json: String,
    pub fee_rate: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedReveal {
    pub kind: String,
    pub sender: String,
    pub recipient: String,
    pub commit_transaction_id: String,
    pub return_sompi: u64,
    pub fee_sompi: u64,
    pub mass: u64,
    pub payload_json: String,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedReveal {
    pub transaction_id: String,
    pub fee_sompi: u64,
    pub mass: u64,
    pub submit_json: String,
    pub review_hash: String,
}

pub(crate) struct BuiltReveal {
    pub(crate) tx: Transaction,
    pub(crate) entry: UtxoEntry,
    pub(crate) redeem_script: Vec<u8>,
    pub(crate) review: PreparedReveal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InscriptionSignatureScheme {
    Schnorr,
    Ecdsa,
}

pub fn prepare_inscription(request: &InscriptionRequest) -> Result<InscriptionPlan> {
    prepare_inscription_with_scheme(request, InscriptionSignatureScheme::Schnorr)
}

pub(crate) fn prepare_inscription_ecdsa(request: &InscriptionRequest) -> Result<InscriptionPlan> {
    prepare_inscription_with_scheme(request, InscriptionSignatureScheme::Ecdsa)
}

fn prepare_inscription_with_scheme(
    request: &InscriptionRequest,
    scheme: InscriptionSignatureScheme,
) -> Result<InscriptionPlan> {
    let sender = checked_address(&request.sender)?;
    match scheme {
        InscriptionSignatureScheme::Schnorr if sender.version != Version::PubKey => {
            return Err(CoreError::InvalidRequest(
                "Schnorr inscription sender must be a PubKey address".into(),
            ));
        }
        InscriptionSignatureScheme::Ecdsa if sender.version != Version::PubKeyECDSA => {
            return Err(CoreError::InvalidRequest(
                "Tangem sender must be a PubKeyECDSA address".into(),
            ));
        }
        _ => {}
    }
    checked_address(&request.recipient)?;
    let (namespace, payload_json) = canonical_payload(request)?;
    let mut builder = ScriptBuilder::new();
    builder
        .add_data(sender.payload.as_slice())
        .and_then(|b| {
            b.add_op(match scheme {
                InscriptionSignatureScheme::Schnorr => OpCheckSig,
                InscriptionSignatureScheme::Ecdsa => OpCheckSigECDSA,
            })
        })
        .and_then(|b| b.add_op(OpFalse))
        .and_then(|b| b.add_op(OpIf))
        .and_then(|b| b.add_data(namespace.as_bytes()))
        .and_then(|b| b.add_i64(0))
        .and_then(|b| b.add_data(payload_json.as_bytes()))
        .and_then(|b| b.add_op(OpEndIf))
        .map_err(|e| CoreError::Transaction(e.to_string()))?;
    let redeem_script = builder.drain();
    let spk = pay_to_script_hash_script(&redeem_script);
    let commit_address = extract_script_pub_key_address(&spk, Prefix::Mainnet)
        .map_err(|e| CoreError::Transaction(e.to_string()))?;
    Ok(InscriptionPlan {
        kind: request.kind.to_lowercase(),
        commit_address: commit_address.to_string(),
        commit_amount_sompi: COMMIT_AMOUNT_SOMPI,
        namespace: namespace.into(),
        payload_json,
        redeem_script_hex: hex::encode(redeem_script),
    })
}

pub fn prepare_reveal(request: &RevealRequest) -> Result<PreparedReveal> {
    Ok(build_reveal(request, InscriptionSignatureScheme::Schnorr)?.review)
}

pub fn sign_reveal(
    secret: &str,
    request: &RevealRequest,
    approved_review_hash: &str,
) -> Result<SignedReveal> {
    if derive_address(secret)?.to_string() != request.operation.sender {
        return Err(CoreError::InvalidRequest(
            "seed does not control sender".into(),
        ));
    }
    let mut built = build_reveal(request, InscriptionSignatureScheme::Schnorr)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = derive_key(secret)?;
    let populated = SignableTransaction::with_entries(built.tx.clone(), vec![built.entry.clone()]);
    let signature = sign_input(&populated.as_verifiable(), 0, &*key, SIG_HASH_ALL);
    built.tx.inputs[0].signature_script =
        pay_to_script_hash_signature_script(built.redeem_script, signature)
            .map_err(|e| CoreError::Transaction(e.to_string()))?;
    built.tx.finalize();
    let transaction_id = built.tx.id().to_string();
    Ok(SignedReveal {
        transaction_id,
        fee_sompi: built.review.fee_sompi,
        mass: built.review.mass,
        submit_json: crate::transaction::submit_json(&built.tx)?,
        review_hash: built.review.review_hash,
    })
}

pub(crate) fn build_reveal_ecdsa(request: &RevealRequest) -> Result<BuiltReveal> {
    build_reveal(request, InscriptionSignatureScheme::Ecdsa)
}

fn build_reveal(
    request: &RevealRequest,
    scheme: InscriptionSignatureScheme,
) -> Result<BuiltReveal> {
    if !request.fee_rate.is_finite() || !(1.0..=1000.0).contains(&request.fee_rate) {
        return Err(CoreError::InvalidRequest("fee rate out of range".into()));
    }
    let plan = prepare_inscription_with_scheme(&request.operation, scheme)?;
    let sender = checked_address(&request.operation.sender)?;
    let txid = kaspa_consensus_core::tx::TransactionId::from_str(&request.commit_transaction_id)
        .map_err(|_| CoreError::UntrustedUtxo("invalid commit transaction id".into()))?;
    let commit_address = checked_address(&plan.commit_address)?;
    let expected_spk = pay_to_address_script(&commit_address);
    let value: Value = serde_json::from_str(&request.commit_utxos_json)
        .map_err(|_| CoreError::UntrustedUtxo("invalid JSON".into()))?;
    let item = value
        .as_array()
        .ok_or_else(|| CoreError::UntrustedUtxo("expected array".into()))?
        .iter()
        .find(|item| {
            item.pointer("/outpoint/transactionId")
                .and_then(Value::as_str)
                == Some(request.commit_transaction_id.as_str())
                && item.pointer("/outpoint/index").and_then(value_as_u64) == Some(0)
        })
        .ok_or_else(|| CoreError::UntrustedUtxo("commit output is not yet available".into()))?;
    if item.get("address").and_then(Value::as_str) != Some(plan.commit_address.as_str()) {
        return Err(CoreError::UntrustedUtxo("commit address mismatch".into()));
    }
    let entry_value = item
        .get("utxoEntry")
        .ok_or_else(|| CoreError::UntrustedUtxo("missing entry".into()))?;
    let amount = value_as_u64(
        entry_value
            .get("amount")
            .ok_or_else(|| CoreError::UntrustedUtxo("missing amount".into()))?,
    )
    .ok_or_else(|| CoreError::UntrustedUtxo("invalid amount".into()))?;
    if amount != COMMIT_AMOUNT_SOMPI {
        return Err(CoreError::UntrustedUtxo("unexpected commit amount".into()));
    }
    let script_hex = entry_value
        .pointer("/scriptPublicKey/scriptPublicKey")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::UntrustedUtxo("missing script".into()))?;
    if hex::decode(script_hex)
        .map_err(|_| CoreError::UntrustedUtxo("invalid script".into()))?
        .as_slice()
        != expected_spk.script()
    {
        return Err(CoreError::UntrustedUtxo("commit script mismatch".into()));
    }
    let daa = entry_value
        .get("blockDaaScore")
        .and_then(value_as_u64)
        .unwrap_or_default();
    let entry = UtxoEntry::new(amount, expected_spk, daa, false, None);
    let redeem_script =
        hex::decode(&plan.redeem_script_hex).map_err(|_| CoreError::Serialization)?;
    let estimated_signature =
        pay_to_script_hash_signature_script(redeem_script.clone(), vec![0; 66])
            .map_err(|e| CoreError::Transaction(e.to_string()))?;
    let mass_calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut fee = 0u64;
    let (mut tx, mass, return_sompi) = loop {
        let return_sompi = amount
            .checked_sub(fee)
            .ok_or(CoreError::InsufficientFunds)?;
        if return_sompi < DUST_LIMIT_SOMPI {
            return Err(CoreError::InsufficientFunds);
        }
        let tx = Transaction::new(
            0,
            vec![TransactionInput::new(
                TransactionOutpoint::new(txid, 0),
                estimated_signature.clone(),
                0,
                1,
            )],
            vec![TransactionOutput::new(
                return_sompi,
                pay_to_address_script(&sender),
            )],
            0,
            SUBNETWORK_ID_NATIVE,
            0,
            vec![],
        );
        let populated = SignableTransaction::with_entries(tx.clone(), vec![entry.clone()]);
        let non_contextual = mass_calculator.calc_non_contextual_masses(&tx);
        let contextual = mass_calculator
            .calc_contextual_masses(&populated.as_verifiable())
            .ok_or_else(|| CoreError::Transaction("storage mass cannot be calculated".into()))?;
        let mass = Mass::new(
            non_contextual,
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&MAINNET_PARAMS.mempool_block_mass_cofactors().after());
        let required = (request.fee_rate * mass as f64).ceil() as u64;
        if fee >= required {
            break (tx, mass, return_sompi);
        }
        fee = required;
    };
    tx.inputs[0].signature_script.clear();
    tx.set_storage_mass(mass);
    tx.finalize();
    let review_data = json!({
        "network":"kaspa:mainnet", "kind":plan.kind, "sender":sender.to_string(),
        "recipient":request.operation.recipient, "commitTransactionId":request.commit_transaction_id,
        "returnSompi":return_sompi, "feeSompi":fee, "mass":mass,
        "namespace":plan.namespace, "payloadJson":plan.payload_json,
        "signatureScheme": match scheme { InscriptionSignatureScheme::Schnorr => "schnorr", InscriptionSignatureScheme::Ecdsa => "ecdsa" },
        "redeemScript":plan.redeem_script_hex,
        "outputScript":hex::encode(tx.outputs[0].script_public_key.script())
    });
    let review_hash = hex::encode(Sha256::digest(
        serde_json::to_vec(&review_data).map_err(|_| CoreError::Serialization)?,
    ));
    let review = PreparedReveal {
        kind: request.operation.kind.to_lowercase(),
        sender: sender.to_string(),
        recipient: request.operation.recipient.clone(),
        commit_transaction_id: request.commit_transaction_id.clone(),
        return_sompi,
        fee_sompi: fee,
        mass,
        payload_json: plan.payload_json,
        review_hash,
    };
    Ok(BuiltReveal {
        tx,
        entry,
        redeem_script,
        review,
    })
}

fn checked_address(raw: &str) -> Result<Address> {
    if !raw.starts_with("kaspa:") {
        return Err(CoreError::InvalidAddress);
    }
    Address::try_from(raw).map_err(|_| CoreError::InvalidAddress)
}

fn quoted(value: &str) -> Result<String> {
    serde_json::to_string(value).map_err(|_| CoreError::Serialization)
}

fn canonical_payload(request: &InscriptionRequest) -> Result<(&'static str, String)> {
    let to = checked_address(&request.recipient)?.to_string();
    let ticker = request.ticker.trim().to_lowercase();
    if !ticker.is_empty()
        && (!ticker
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            || ticker.len() > 32)
    {
        return Err(CoreError::InvalidRequest("invalid ticker".into()));
    }
    match request.kind.to_lowercase().as_str() {
        "krc20" => {
            if ticker.is_empty()
                || request.amount.is_empty()
                || !request.amount.chars().all(|c| c.is_ascii_digit())
                || request.amount == "0"
            {
                return Err(CoreError::InvalidRequest("invalid KRC-20 transfer".into()));
            }
            Ok((
                "kasplex",
                format!(
                    "{{\"p\":\"krc-20\",\"op\":\"transfer\",\"tick\":{},\"to\":{},\"amt\":{}}}",
                    quoted(&ticker)?,
                    quoted(&to)?,
                    quoted(&request.amount)?
                ),
            ))
        }
        "krc721" => {
            if ticker.is_empty()
                || request.token_id.trim().is_empty()
                || request.token_id.len() > 128
            {
                return Err(CoreError::InvalidRequest("invalid KRC-721 transfer".into()));
            }
            Ok(("kspr", format!("{{\"p\":\"krc-721\",\"op\":\"transfer\",\"tick\":{},\"to\":{},\"tokenId\":{}}}", quoted(&ticker)?, quoted(&to)?, quoted(request.token_id.trim())?)))
        }
        "kns" => {
            let id = request.asset_id.trim();
            if !id.ends_with("i0")
                || id.len() != 66
                || !id[..64].chars().all(|c| c.is_ascii_hexdigit())
            {
                return Err(CoreError::InvalidRequest("invalid KNS asset id".into()));
            }
            Ok((
                "kns",
                format!(
                    "{{\"op\":\"transfer\",\"id\":{},\"to\":{},\"p\":\"domain\"}}",
                    quoted(&id.to_lowercase())?,
                    quoted(&to)?
                ),
            ))
        }
        _ => Err(CoreError::InvalidRequest(
            "unsupported inscription kind".into(),
        )),
    }
}

fn value_as_u64(value: &Value) -> Option<u64> {
    match value {
        Value::String(s) => s.parse().ok(),
        Value::Number(n) => n.as_u64(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ADDRESS: &str = "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";
    #[test]
    fn builds_canonical_protocol_payloads() {
        let mut r = InscriptionRequest {
            kind: "krc20".into(),
            sender: ADDRESS.into(),
            recipient: ADDRESS.into(),
            ticker: "KASPER".into(),
            amount: "123".into(),
            token_id: String::new(),
            asset_id: String::new(),
        };
        let p = prepare_inscription(&r).unwrap();
        assert_eq!(p.namespace, "kasplex");
        assert!(p
            .payload_json
            .starts_with("{\"p\":\"krc-20\",\"op\":\"transfer\",\"tick\":\"kasper\",\"to\":"));
        assert!(p.commit_address.starts_with("kaspa:p"));
        r.kind = "krc721".into();
        r.token_id = "42".into();
        assert_eq!(prepare_inscription(&r).unwrap().namespace, "kspr");
        r.kind = "kns".into();
        r.asset_id = format!("{}i0", "a".repeat(64));
        assert_eq!(prepare_inscription(&r).unwrap().namespace, "kns");
    }

    #[test]
    fn prepares_and_signs_reveal_with_bound_review() {
        let operation = InscriptionRequest {
            kind: "krc721".into(),
            sender: ADDRESS.into(),
            recipient: ADDRESS.into(),
            ticker: "TEST".into(),
            amount: String::new(),
            token_id: "7".into(),
            asset_id: String::new(),
        };
        let plan = prepare_inscription(&operation).unwrap();
        let commit_address = Address::try_from(plan.commit_address.as_str()).unwrap();
        let script = hex::encode(pay_to_address_script(&commit_address).script());
        let commit_id = "22".repeat(32);
        let utxos = json!([{
            "address": plan.commit_address,
            "outpoint": {"transactionId": commit_id, "index": 0},
            "utxoEntry": {"amount": COMMIT_AMOUNT_SOMPI.to_string(), "scriptPublicKey": {"scriptPublicKey": script}, "blockDaaScore": "100", "isCoinbase": false}
        }]).to_string();
        let request = RevealRequest {
            operation,
            commit_transaction_id: commit_id,
            commit_utxos_json: utxos,
            fee_rate: 1.0,
        };
        let prepared = prepare_reveal(&request).unwrap();
        assert!(prepared.fee_sompi > 0);
        let secret = "mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        assert!(matches!(
            sign_reveal(secret, &request, "wrong"),
            Err(CoreError::ReviewMismatch)
        ));
        let signed = sign_reveal(secret, &request, &prepared.review_hash).unwrap();
        assert_eq!(signed.review_hash, prepared.review_hash);
        assert!(signed.submit_json.contains("signatureScript"));
    }

    #[test]
    fn hostile_inscription_fields_fail_closed() {
        let base = InscriptionRequest {
            kind: "krc20".into(),
            sender: ADDRESS.into(),
            recipient: ADDRESS.into(),
            ticker: "TEST".into(),
            amount: "1".into(),
            token_id: String::new(),
            asset_id: String::new(),
        };
        for ticker in ["", "../evil", "A<script>", "A\0B"]
            .into_iter()
            .map(str::to_owned)
            .chain(std::iter::once("A".repeat(10_000)))
        {
            let mut request = base.clone();
            request.ticker = ticker;
            assert!(prepare_inscription(&request).is_err(), "accepted ticker");
        }
        for amount in ["-1", "1.1", "1e9", "NaN"]
            .into_iter()
            .map(str::to_owned)
            .chain(std::iter::once("9".repeat(10_000)))
        {
            let mut request = base.clone();
            request.amount = amount;
            assert!(prepare_inscription(&request).is_err(), "accepted amount");
        }
    }
}
