//! Experimental single-seed P2SH KAS account. This is NOT a post-quantum signature
//! scheme or an adopted wallet standard. Freeze the descriptor before funding.
use crate::transaction::{parse_utxos, Spendable};
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_bip32::{DerivationPath, ExtendedPrivateKey, Language, Mnemonic, PrivateKey};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{ContextualMasses, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{SignableTransaction, Transaction, TransactionInput, TransactionOutput},
};
use kaspa_txscript::{
    extract_script_pub_key_address,
    opcodes::codes::{OpBlake2b, OpCheckSig, OpDup, OpEqualVerify},
    pay_to_address_script, pay_to_script_hash_script, pay_to_script_hash_signature_script,
    script_builder::ScriptBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::str::FromStr;
use zeroize::{Zeroize, Zeroizing};

pub const DESCRIPTOR: &str = "kaspire-hidden-kas-v1";
// Private experimental purpose, deliberately neither ordinary BIP44 nor CLI
// multisig. No xpub export; all children hardened, including branch and index.
pub const PATH_PREFIX: &str = "m/1214346033'/111111'/0'";
pub const GAP: u32 = 20;
pub const MAX_INDEX: u32 = 9999;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HiddenAddress {
    pub branch: u32,
    pub index: u32,
    pub address: String,
    pub key_hash: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub descriptor: String,
    pub recipient: String,
    pub amount_sompi: u64,
    pub fee_rate: f64,
    pub signers: Vec<HiddenAddress>,
    pub change: HiddenAddress,
    pub utxos_json: String,
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidRequest(s.into())
}
fn path(branch: u32, index: u32) -> Result<String> {
    if branch > 1 || index > MAX_INDEX {
        return Err(invalid("Invalid hidden-account derivation coordinates"));
    }
    Ok(format!("{PATH_PREFIX}/{branch}'/{index}'"))
}
#[derive(Clone)]
struct ErasedKey(kaspa_bip32::SecretKey);
impl Drop for ErasedKey {
    fn drop(&mut self) {
        self.0.non_secure_erase();
    }
}
impl PrivateKey for ErasedKey {
    type PublicKey = <kaspa_bip32::SecretKey as PrivateKey>::PublicKey;
    fn from_bytes(bytes: &[u8; 32]) -> kaspa_bip32::Result<Self> {
        kaspa_bip32::SecretKey::from_bytes(bytes).map(Self)
    }
    fn to_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }
    fn derive_child(&self, mut other: [u8; 32]) -> kaspa_bip32::Result<Self> {
        let result = self.0.derive_child(other).map(Self);
        other.zeroize();
        result
    }
    fn public_key(&self) -> Self::PublicKey {
        <kaspa_bip32::SecretKey as PrivateKey>::public_key(&self.0)
    }
}
fn key(secret: &str, branch: u32, index: u32) -> Result<Zeroizing<[u8; 32]>> {
    if secret.starts_with("private:") || secret.starts_with("hd-path:") {
        return Err(invalid("Hidden KAS requires a root mnemonic wallet"));
    }
    let (phrase, passphrase) = crate::mnemonic_secret(secret)?;
    // Mnemonic and Seed zeroize on Drop in the pinned BIP32 implementation;
    // wrap intermediate extended private keys too, rather than leaving their
    // secp SecretKey copies behind when the path fold drops its parents.
    let mnemonic = Mnemonic::new(phrase.to_string(), Language::English)
        .map_err(|_| CoreError::InvalidMnemonic)?;
    let seed = mnemonic.to_seed(&passphrase);
    let master =
        ExtendedPrivateKey::<ErasedKey>::new(seed.as_bytes()).map_err(|_| CoreError::Derivation)?;
    let selected = master
        .derive_path(
            &DerivationPath::from_str(&path(branch, index)?).map_err(|_| CoreError::Derivation)?,
        )
        .map_err(|_| CoreError::Derivation)?;
    Ok(Zeroizing::new(selected.private_key().to_bytes()))
}
// Frozen minimal equivalent of official Silverscript P2PKH's two requirements:
// require(blake2b(pk)==pkh); require(checkSig(s,pk)). Witness: sig, pk, script.
pub fn redeem(key_hash: &str) -> Result<Vec<u8>> {
    let hash = hex::decode(key_hash).map_err(|_| invalid("Invalid public-key hash"))?;
    if hash.len() != 32 || hex::encode(&hash) != key_hash {
        return Err(invalid("Invalid public-key hash"));
    }
    let mut b = ScriptBuilder::new();
    b.add_op(OpDup)
        .and_then(|b| b.add_op(OpBlake2b))
        .and_then(|b| b.add_data(&hash))
        .and_then(|b| b.add_op(OpEqualVerify))
        .and_then(|b| b.add_op(OpCheckSig))
        .map_err(|e| CoreError::Transaction(e.to_string()))?;
    Ok(b.drain())
}
fn check_address(a: &HiddenAddress) -> Result<Address> {
    path(a.branch, a.index)?;
    let address = extract_script_pub_key_address(
        &pay_to_script_hash_script(&redeem(&a.key_hash)?),
        Prefix::Mainnet,
    )
    .map_err(|_| CoreError::InvalidAddress)?;
    if address.to_string() != a.address {
        return Err(invalid("Hidden-account address does not match its script"));
    }
    Ok(address)
}
pub fn derive(secret: &str, branch: u32, start: u32, count: u32) -> Result<Vec<HiddenAddress>> {
    if secret.starts_with("private:") || secret.starts_with("hd-path:") {
        return Err(invalid("Hidden KAS requires a root mnemonic wallet"));
    }
    if count == 0
        || count > 100
        || start
            .checked_add(count - 1)
            .filter(|i| *i <= MAX_INDEX)
            .is_none()
    {
        return Err(invalid("Invalid hidden-account address range"));
    }
    (start..start + count)
        .map(|index| {
            let key = key(secret, branch, index)?;
            let mut pair = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, &*key)
                .map_err(|_| CoreError::Derivation)?;
            let pk = pair.x_only_public_key().0.serialize();
            pair.non_secure_erase();
            let hash = kaspa_hashes::blake2b_simd::Params::new()
                .hash_length(32)
                .hash(&pk);
            let key_hash = hex::encode(hash.as_bytes());
            let address = extract_script_pub_key_address(
                &pay_to_script_hash_script(&redeem(&key_hash)?),
                Prefix::Mainnet,
            )
            .map_err(|_| CoreError::InvalidAddress)?
            .to_string();
            Ok(HiddenAddress {
                branch,
                index,
                address,
                key_hash,
            })
        })
        .collect()
}
struct Built {
    tx: Transaction,
    inputs: Vec<(Spendable, usize)>,
    review: Value,
}
fn build(r: &Request) -> Result<Built> {
    if r.descriptor != DESCRIPTOR
        || r.signers.is_empty()
        || r.signers.len() > 80
        || r.change.branch != 1
    {
        return Err(invalid("Invalid hidden KAS descriptor or signer set"));
    }
    if !r.fee_rate.is_finite() || !(1.0..=1000.0).contains(&r.fee_rate) || r.amount_sompi < 10000 {
        return Err(invalid("Invalid amount or fee rate"));
    }
    let recipient =
        Address::try_from(r.recipient.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if recipient.prefix != Prefix::Mainnet
        || !matches!(
            recipient.version,
            Version::PubKey | Version::ScriptHash | Version::PubKeyECDSA
        )
    {
        return Err(invalid(
            "Hidden KAS test supports Kaspa Mainnet payments only",
        ));
    }
    let change = check_address(&r.change)?;
    let mut seen = HashSet::new();
    for a in &r.signers {
        check_address(a)?;
        if !seen.insert(a.address.clone())
            || a.address == r.change.address
            || a.address == r.recipient
        {
            return Err(invalid("Duplicate or reused hidden-account address"));
        }
    }
    if r.recipient == r.change.address {
        return Err(invalid("Recipient cannot be the reserved change address"));
    }
    let raw: Value =
        serde_json::from_str(&r.utxos_json).map_err(|_| invalid("Invalid UTXO JSON"))?;
    let rows = raw
        .as_array()
        .ok_or_else(|| invalid("Invalid UTXO array"))?;
    if rows.is_empty() || rows.len() > 80 {
        return Err(invalid(
            "Hidden KAS requires 1–80 spendable outputs; no outputs are silently omitted",
        ));
    }
    let mut inputs = vec![];
    let mut outpoints = HashSet::new();
    for row in rows {
        let i = r
            .signers
            .iter()
            .position(|a| row["address"].as_str() == Some(&a.address))
            .ok_or_else(|| invalid("UTXO belongs to an unreviewed address"))?;
        let e = &row["utxoEntry"];
        if e["isCoinbase"] != false
            || e["scriptPublicKey"]["version"] != 0
            || (!e["covenantId"].is_null())
            || (!e["covenant"].is_null())
        {
            return Err(invalid(
                "Hidden KAS cannot spend coinbase, covenant or nonstandard outputs",
            ));
        }
        let a = check_address(&r.signers[i])?;
        let mut parsed = parse_utxos(&json!([row]).to_string(), &a)?;
        let entry = parsed
            .pop()
            .ok_or_else(|| invalid("Missing spendable UTXO"))?;
        if !outpoints.insert(entry.outpoint) {
            return Err(invalid("Duplicate input"));
        }
        inputs.push((entry, i));
    }
    if r.signers
        .iter()
        .enumerate()
        .any(|(i, _)| !inputs.iter().any(|(_, j)| *j == i))
    {
        return Err(invalid("Unused signer in hidden KAS request"));
    }
    inputs.sort_by_key(|(e, _)| (e.outpoint.transaction_id, e.outpoint.index));
    let total = inputs
        .iter()
        .try_fold(0u64, |sum, (e, _)| sum.checked_add(e.entry.amount))
        .ok_or_else(|| invalid("Amount overflow"))?;
    let calc = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut fee = 0u64;
    for _ in 0..32 {
        let remainder = total
            .checked_sub(r.amount_sompi)
            .and_then(|v| v.checked_sub(fee))
            .ok_or_else(|| invalid("Insufficient KAS including network fee"))?;
        if remainder > 0 && remainder < 10000 {
            return Err(invalid(
                "Change is below the minimum; reduce the amount slightly",
            ));
        }
        let ins = inputs
            .iter()
            .map(|(e, i)| {
                // Exact final witness size: push65 signature, push32 x-only key,
                // push frozen redeem script. All pubkey pushes have fixed length.
                let mut b = ScriptBuilder::new();
                b.add_data(&[0; 65]).unwrap().add_data(&[0; 32]).unwrap();
                let sig = pay_to_script_hash_signature_script(
                    redeem(&r.signers[*i].key_hash).unwrap(),
                    b.drain(),
                )
                .unwrap();
                TransactionInput::new(e.outpoint, sig, 0, 1)
            })
            .collect();
        let mut outputs = vec![TransactionOutput::new(
            r.amount_sompi,
            pay_to_address_script(&recipient),
        )];
        if remainder > 0 {
            outputs.push(TransactionOutput::new(
                remainder,
                pay_to_address_script(&change),
            ));
        }
        let mut tx = Transaction::new(0, ins, outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        let entries = inputs.iter().map(|(e, _)| e.entry.clone()).collect();
        let signable = SignableTransaction::with_entries(tx.clone(), entries);
        let context = calc
            .calc_contextual_masses(&signable.as_verifiable())
            .ok_or_else(|| invalid("Cannot calculate storage mass"))?;
        let mass = Mass::new(
            calc.calc_non_contextual_masses(&tx),
            ContextualMasses::new(context.storage_mass),
        )
        .normalized_max(&MAINNET_PARAMS.block_mass_cofactors());
        if mass > 100000 {
            return Err(invalid(
                "Transaction exceeds standard mass; no outputs were signed",
            ));
        }
        let required = (mass as f64 * r.fee_rate).ceil() as u64;
        if fee < required {
            fee = required;
            continue;
        }
        tx.set_storage_mass(mass);
        for input in &mut tx.inputs {
            input.signature_script.clear();
        }
        tx.finalize();
        let mut review = json!({"descriptor":DESCRIPTOR,"derivationPrefix":PATH_PREFIX,"recipient":r.recipient,
            "amountSompi":r.amount_sompi,"totalInputSompi":total,"changeSompi":remainder,"changeAddress":r.change.address,
            "feeSompi":fee,"mass":mass,"inputCount":inputs.len(),"signers":r.signers,"change":r.change,
            "transaction":crate::transaction::submit_json(&tx)?,"utxos":rows});
        let hash = hex::encode(Sha256::digest(
            serde_json::to_vec(&review).map_err(|_| CoreError::Serialization)?,
        ));
        review["reviewHash"] = json!(hash);
        return Ok(Built { tx, inputs, review });
    }
    Err(invalid("Fee estimation did not converge"))
}
pub fn prepare(r: &Request) -> Result<Value> {
    Ok(build(r)?.review)
}
pub fn sign(secret: &str, r: &Request, hash: &str) -> Result<Value> {
    for a in r.signers.iter().chain(std::iter::once(&r.change)) {
        if derive(secret, a.branch, a.index, 1)?.first() != Some(a) {
            return Err(invalid("Seed does not control the reviewed hidden account"));
        }
    }
    let mut b = build(r)?;
    if b.review["reviewHash"].as_str() != Some(hash) {
        return Err(CoreError::ReviewMismatch);
    }
    let entries = b
        .inputs
        .iter()
        .map(|(e, _)| e.entry.clone())
        .collect::<Vec<_>>();
    let signable = SignableTransaction::with_entries(b.tx.clone(), entries.clone());
    for (index, (_, i)) in b.inputs.iter().enumerate() {
        let a = &r.signers[*i];
        let key = key(secret, a.branch, a.index)?;
        let mut pair = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, &*key)
            .map_err(|_| CoreError::Derivation)?;
        let digest = calc_schnorr_signature_hash(
            &signable.as_verifiable(),
            index,
            SIG_HASH_ALL,
            &SigHashReusedValuesUnsync::new(),
        );
        let message = secp256k1::Message::from_digest_slice(&digest.as_bytes())
            .map_err(|_| CoreError::Derivation)?;
        let mut signature = pair.sign_schnorr(message).as_ref().to_vec();
        signature.push(SIG_HASH_ALL.to_u8());
        let public = pair.x_only_public_key().0.serialize();
        pair.non_secure_erase();
        let mut witness = ScriptBuilder::new();
        witness
            .add_data(&signature)
            .and_then(|b| b.add_data(&public))
            .map_err(|e| CoreError::Transaction(e.to_string()))?;
        b.tx.inputs[index].signature_script =
            pay_to_script_hash_signature_script(redeem(&a.key_hash)?, witness.drain())
                .map_err(|e| CoreError::Transaction(e.to_string()))?;
    }
    b.tx.finalize();
    crate::kcc20::simulate_all(&b.tx, &entries)?;
    Ok(
        json!({"transactionId":b.tx.id().to_string(),"submitJson":crate::transaction::submit_json(&b.tx)?,"reviewHash":hash,"feeSompi":b.review["feeSompi"]}),
    )
}

/// Imported journals cannot introduce unreviewed bytes or somebody else's
/// transaction. Rebuild the unsigned payment and validate every stored witness.
pub fn verify_saved(secret: &str, saved: &Value) -> Result<()> {
    let r: Request = serde_json::from_value(saved["request"].clone())
        .map_err(|_| invalid("Missing saved request"))?;
    for a in r.signers.iter().chain(std::iter::once(&r.change)) {
        if derive(secret, a.branch, a.index, 1)?.first() != Some(a) {
            return Err(invalid("Recovery request belongs to another seed"));
        }
    }
    let mut b = build(&r)?;
    if b.review["reviewHash"] != saved["reviewHash"] {
        return Err(CoreError::ReviewMismatch);
    }
    let submitted: Value = serde_json::from_str(
        saved["submitJson"]
            .as_str()
            .ok_or_else(|| invalid("Missing signed bytes"))?,
    )
    .map_err(|_| invalid("Invalid signed bytes"))?;
    let inputs = submitted["transaction"]["inputs"]
        .as_array()
        .ok_or_else(|| invalid("Missing signed inputs"))?;
    if inputs.len() != b.tx.inputs.len() {
        return Err(invalid("Saved input count differs"));
    }
    for (i, item) in inputs.iter().enumerate() {
        let script = item["signatureScript"]
            .as_str()
            .ok_or_else(|| invalid("Missing saved signature"))?;
        if script.len() > 600 {
            return Err(invalid("Saved witness too large"));
        }
        let witness = hex::decode(script).map_err(|_| invalid("Invalid saved signature"))?;
        if witness.len() != 137
            || witness[0] != 65
            || witness[65] != SIG_HASH_ALL.to_u8()
            || witness[66] != 32
        {
            return Err(invalid(
                "Saved hidden KAS witness must use the frozen SIGHASH_ALL layout",
            ));
        }
        b.tx.inputs[i].signature_script = witness;
    }
    b.tx.finalize();
    if saved["transactionId"].as_str() != Some(&b.tx.id().to_string())
        || submitted
            != serde_json::from_str::<Value>(&crate::transaction::submit_json(&b.tx)?)
                .map_err(|_| CoreError::Serialization)?
    {
        return Err(invalid("Saved transaction differs from reviewed payment"));
    }
    crate::kcc20::simulate_all(
        &b.tx,
        &b.inputs
            .iter()
            .map(|(e, _)| e.entry.clone())
            .collect::<Vec<_>>(),
    )
}
