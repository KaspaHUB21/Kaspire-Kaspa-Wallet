use crate::{
    inscription::{build_reveal_ecdsa, prepare_inscription_ecdsa},
    transaction::{build as build_transaction, submit_json, SendRequest},
    CoreError, InscriptionPlan, InscriptionRequest, PreparedReveal, PreparedTransaction, Result,
    RevealRequest, SignedReveal, SignedTransaction,
};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    hashing::{
        sighash::{calc_ecdsa_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    tx::SignableTransaction,
};
use kaspa_txscript::{pay_to_script_hash_signature_script, script_builder::ScriptBuilder};
use secp256k1::{ecdsa::Signature, Message, PublicKey};
use serde::{Deserialize, Serialize};

const TANGEM_DERIVATION_PATH: &str = "m/44'/111111'/0'/0/0";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TangemCommitRequest {
    pub operation: InscriptionRequest,
    pub public_key_hex: String,
    pub fee_rate: f64,
    pub utxos_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedTangemCommit {
    pub plan: InscriptionPlan,
    pub transaction: PreparedTransaction,
    pub hashes: Vec<String>,
    pub public_key_hex: String,
    pub derivation_path: String,
    pub signature_scheme: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TangemRevealRequest {
    pub reveal: RevealRequest,
    pub public_key_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedTangemReveal {
    pub transaction: PreparedReveal,
    pub hashes: Vec<String>,
    pub public_key_hex: String,
    pub derivation_path: String,
    pub signature_scheme: String,
}

pub fn tangem_address(public_key_hex: &str) -> Result<String> {
    let public_key = checked_public_key(public_key_hex)?;
    Ok(Address::new(
        Prefix::Mainnet,
        Version::PubKeyECDSA,
        &public_key.serialize(),
    )
    .to_string())
}

pub fn prepare_tangem_commit(request: &TangemCommitRequest) -> Result<PreparedTangemCommit> {
    let (plan, send, public_key) = checked_commit(request)?;
    let built = build_transaction(&send)?;
    let hashes = ecdsa_hashes(&built.signable);
    Ok(PreparedTangemCommit {
        plan,
        transaction: built.review,
        hashes,
        public_key_hex: hex::encode(public_key.serialize()),
        derivation_path: TANGEM_DERIVATION_PATH.into(),
        signature_scheme: "secp256k1-ecdsa-compact".into(),
    })
}

pub fn finalize_tangem_commit(
    request: &TangemCommitRequest,
    approved_review_hash: &str,
    signatures: &[String],
) -> Result<SignedTransaction> {
    let (_, send, public_key) = checked_commit(request)?;
    let mut built = build_transaction(&send)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    apply_ecdsa_signatures(&mut built.signable, &public_key, signatures)?;
    built.signable.tx.finalize();
    let transaction_id = built.signable.tx.id().to_string();
    Ok(SignedTransaction {
        transaction_id,
        fee_sompi: built.review.fee_sompi,
        mass: built.review.mass,
        submit_json: submit_json(&built.signable.tx)?,
        review_hash: built.review.review_hash,
    })
}

pub fn prepare_tangem_reveal(request: &TangemRevealRequest) -> Result<PreparedTangemReveal> {
    let public_key = checked_reveal(request)?;
    let built = build_reveal_ecdsa(&request.reveal)?;
    let signable = SignableTransaction::with_entries(built.tx.clone(), vec![built.entry]);
    Ok(PreparedTangemReveal {
        transaction: built.review,
        hashes: ecdsa_hashes(&signable),
        public_key_hex: hex::encode(public_key.serialize()),
        derivation_path: TANGEM_DERIVATION_PATH.into(),
        signature_scheme: "secp256k1-ecdsa-compact".into(),
    })
}

pub fn finalize_tangem_reveal(
    request: &TangemRevealRequest,
    approved_review_hash: &str,
    signatures: &[String],
) -> Result<SignedReveal> {
    let public_key = checked_reveal(request)?;
    let mut built = build_reveal_ecdsa(&request.reveal)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let mut signable =
        SignableTransaction::with_entries(built.tx.clone(), vec![built.entry.clone()]);
    let signature_scripts = checked_ecdsa_signature_scripts(&signable, &public_key, signatures)?;
    built.tx.inputs[0].signature_script =
        pay_to_script_hash_signature_script(built.redeem_script, signature_scripts[0].clone())
            .map_err(|error| CoreError::Transaction(error.to_string()))?;
    built.tx.finalize();
    signable.tx = built.tx.clone();
    Ok(SignedReveal {
        transaction_id: built.tx.id().to_string(),
        fee_sompi: built.review.fee_sompi,
        mass: built.review.mass,
        submit_json: submit_json(&built.tx)?,
        review_hash: built.review.review_hash,
    })
}

fn checked_commit(
    request: &TangemCommitRequest,
) -> Result<(InscriptionPlan, SendRequest, PublicKey)> {
    if request.operation.kind.to_lowercase() != "krc721" {
        return Err(CoreError::InvalidRequest(
            "Tangem Rescue signs only KRC-721 transfers".into(),
        ));
    }
    let public_key = checked_public_key(&request.public_key_hex)?;
    require_sender(&request.operation.sender, &public_key)?;
    let plan = prepare_inscription_ecdsa(&request.operation)?;
    let send = SendRequest {
        sender: request.operation.sender.clone(),
        recipient: plan.commit_address.clone(),
        amount_sompi: plan.commit_amount_sompi,
        fee_rate: request.fee_rate,
        utxos_json: request.utxos_json.clone(),
        send_all: false,
    };
    Ok((plan, send, public_key))
}

fn checked_reveal(request: &TangemRevealRequest) -> Result<PublicKey> {
    if request.reveal.operation.kind.to_lowercase() != "krc721" {
        return Err(CoreError::InvalidRequest(
            "Tangem Rescue signs only KRC-721 transfers".into(),
        ));
    }
    let public_key = checked_public_key(&request.public_key_hex)?;
    require_sender(&request.reveal.operation.sender, &public_key)?;
    Ok(public_key)
}

fn require_sender(sender: &str, public_key: &PublicKey) -> Result<()> {
    let address = Address::try_from(sender).map_err(|_| CoreError::InvalidAddress)?;
    if address.prefix != Prefix::Mainnet
        || address.version != Version::PubKeyECDSA
        || address.payload.as_slice() != public_key.serialize()
    {
        return Err(CoreError::InvalidRequest(
            "scanned Tangem key does not control the sender".into(),
        ));
    }
    Ok(())
}

fn checked_public_key(raw: &str) -> Result<PublicKey> {
    let bytes = hex::decode(raw)
        .map_err(|_| CoreError::InvalidRequest("invalid Tangem public key".into()))?;
    PublicKey::from_slice(&bytes)
        .map_err(|_| CoreError::InvalidRequest("invalid Tangem public key".into()))
}

fn ecdsa_hashes(signable: &SignableTransaction) -> Vec<String> {
    let reused = SigHashReusedValuesUnsync::new();
    (0..signable.tx.inputs.len())
        .map(|index| {
            hex::encode(
                calc_ecdsa_signature_hash(&signable.as_verifiable(), index, SIG_HASH_ALL, &reused)
                    .as_bytes(),
            )
        })
        .collect()
}

fn checked_ecdsa_signature_scripts(
    signable: &SignableTransaction,
    public_key: &PublicKey,
    signatures: &[String],
) -> Result<Vec<Vec<u8>>> {
    if signatures.len() != signable.tx.inputs.len() || signatures.is_empty() {
        return Err(CoreError::InvalidRequest(
            "Tangem returned the wrong number of signatures".into(),
        ));
    }
    let reused = SigHashReusedValuesUnsync::new();
    signatures
        .iter()
        .enumerate()
        .map(|(index, raw)| {
            let bytes = hex::decode(raw).map_err(|_| {
                CoreError::InvalidRequest("Tangem returned an invalid signature".into())
            })?;
            let mut signature = Signature::from_compact(&bytes).map_err(|_| {
                CoreError::InvalidRequest("Tangem signature is not compact ECDSA".into())
            })?;
            signature.normalize_s();
            let hash =
                calc_ecdsa_signature_hash(&signable.as_verifiable(), index, SIG_HASH_ALL, &reused);
            let message = Message::from_digest_slice(&hash.as_bytes())
                .map_err(|_| CoreError::InvalidRequest("invalid Kaspa signing hash".into()))?;
            secp256k1::SECP256K1
                .verify_ecdsa(&message, &signature, public_key)
                .map_err(|_| {
                    CoreError::InvalidRequest(
                        "Tangem signature does not match the reviewed transaction".into(),
                    )
                })?;
            let mut signature_and_type = signature.serialize_compact().to_vec();
            signature_and_type.push(SIG_HASH_ALL.to_u8());
            ScriptBuilder::new()
                .add_data(&signature_and_type)
                .map(|builder| builder.drain())
                .map_err(|error| CoreError::Transaction(error.to_string()))
        })
        .collect()
}

fn apply_ecdsa_signatures(
    signable: &mut SignableTransaction,
    public_key: &PublicKey,
    signatures: &[String],
) -> Result<()> {
    let scripts = checked_ecdsa_signature_scripts(signable, public_key, signatures)?;
    for (input, script) in signable.tx.inputs.iter_mut().zip(scripts) {
        input.signature_script = script;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_consensus_core::{
        hashing::{sighash::calc_ecdsa_signature_hash, sighash_type::SIG_HASH_ALL},
        tx::TransactionId,
    };
    use secp256k1::{Secp256k1, SecretKey};
    use serde_json::json;
    use std::str::FromStr;

    fn fixture() -> (TangemCommitRequest, SecretKey) {
        let secret = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let public_key = PublicKey::from_secret_key(&Secp256k1::new(), &secret);
        let sender = tangem_address(&hex::encode(public_key.serialize())).unwrap();
        let recipient = "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";
        let address = Address::try_from(sender.as_str()).unwrap();
        let script = hex::encode(kaspa_txscript::pay_to_address_script(&address).script());
        let utxos = json!([{
            "address": sender,
            "outpoint": {"transactionId": "11".repeat(32), "index": 0},
            "utxoEntry": {
                "amount": "100000000", "blockDaaScore": "1", "isCoinbase": false,
                "scriptPublicKey": {"scriptPublicKey": script}
            }
        }]);
        (
            TangemCommitRequest {
                operation: InscriptionRequest {
                    kind: "krc721".into(),
                    sender: address.to_string(),
                    recipient: recipient.into(),
                    ticker: "TEST".into(),
                    amount: String::new(),
                    token_id: "7".into(),
                    asset_id: String::new(),
                },
                public_key_hex: hex::encode(public_key.serialize()),
                fee_rate: 1.0,
                utxos_json: utxos.to_string(),
            },
            secret,
        )
    }

    #[test]
    fn tangem_commit_accepts_only_matching_compact_ecdsa_signatures() {
        let (request, secret) = fixture();
        let prepared = prepare_tangem_commit(&request).unwrap();
        assert_eq!(prepared.signature_scheme, "secp256k1-ecdsa-compact");
        let (_, send, _) = checked_commit(&request).unwrap();
        let built = build_transaction(&send).unwrap();
        let reused = SigHashReusedValuesUnsync::new();
        let hash =
            calc_ecdsa_signature_hash(&built.signable.as_verifiable(), 0, SIG_HASH_ALL, &reused);
        let message = Message::from_digest_slice(&hash.as_bytes()).unwrap();
        let signature = Secp256k1::new().sign_ecdsa(&message, &secret);
        let signed = finalize_tangem_commit(
            &request,
            &prepared.transaction.review_hash,
            &[hex::encode(signature.serialize_compact())],
        )
        .unwrap();
        assert!(signed.submit_json.contains("signatureScript"));

        let wrong = SecretKey::from_slice(&[8u8; 32]).unwrap();
        let bad = Secp256k1::new().sign_ecdsa(&message, &wrong);
        assert!(finalize_tangem_commit(
            &request,
            &prepared.transaction.review_hash,
            &[hex::encode(bad.serialize_compact())],
        )
        .is_err());
        assert!(TransactionId::from_str(&signed.transaction_id).is_ok());
    }

    #[test]
    fn tangem_reveal_uses_ecdsa_redeem_script_and_external_signature() {
        let (commit_request, secret) = fixture();
        let plan = prepare_inscription_ecdsa(&commit_request.operation).unwrap();
        let commit_address = Address::try_from(plan.commit_address.as_str()).unwrap();
        let script = hex::encode(kaspa_txscript::pay_to_address_script(&commit_address).script());
        let commit_id = "22".repeat(32);
        let commit_utxos = json!([{
            "address": plan.commit_address,
            "outpoint": {"transactionId": commit_id, "index": 0},
            "utxoEntry": {
                "amount": plan.commit_amount_sompi.to_string(),
                "scriptPublicKey": {"scriptPublicKey": script},
                "blockDaaScore": "100", "isCoinbase": false
            }
        }]);
        let request = TangemRevealRequest {
            reveal: RevealRequest {
                operation: commit_request.operation.clone(),
                commit_transaction_id: commit_id,
                commit_utxos_json: commit_utxos.to_string(),
                fee_rate: 1.0,
            },
            public_key_hex: commit_request.public_key_hex,
        };
        let prepared = prepare_tangem_reveal(&request).unwrap();
        let built = build_reveal_ecdsa(&request.reveal).unwrap();
        assert!(built
            .redeem_script
            .contains(&kaspa_txscript::opcodes::codes::OpCheckSigECDSA));
        let signable = SignableTransaction::with_entries(built.tx, vec![built.entry]);
        let reused = SigHashReusedValuesUnsync::new();
        let hash = calc_ecdsa_signature_hash(&signable.as_verifiable(), 0, SIG_HASH_ALL, &reused);
        let message = Message::from_digest_slice(&hash.as_bytes()).unwrap();
        let signature = Secp256k1::new().sign_ecdsa(&message, &secret);
        let signed = finalize_tangem_reveal(
            &request,
            &prepared.transaction.review_hash,
            &[hex::encode(signature.serialize_compact())],
        )
        .unwrap();
        assert!(signed.submit_json.contains("signatureScript"));
        assert!(TransactionId::from_str(&signed.transaction_id).is_ok());
    }
}
