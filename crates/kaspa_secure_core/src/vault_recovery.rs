//! Password-only portable metadata envelope. Never contains wallet signing keys.
//! Experimental RustCrypto PQ implementations are not independently audited.
use crate::{CoreError, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    aead::{Aead, Payload},
    KeyInit, XChaCha20Poly1305, XNonce,
};
use ml_dsa::{Keypair, MlDsa87, Signature, Signer, SigningKey, Verifier};
use ml_kem::{Ciphertext, Decapsulate, DecapsulationKey1024, MlKem1024};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

const FORMAT: &str = "kaspire-vault-recovery-pq-v1";
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    format: String,
    salt: String,
    nonce: String,
    kem_ciphertext: String,
    ciphertext: String,
    signature: String,
}
fn fail() -> CoreError {
    CoreError::InvalidRequest("Wrong recovery password or damaged/unsupported recovery file".into())
}
fn random<const N: usize>() -> Result<[u8; N]> {
    let mut b = [0; N];
    getrandom::getrandom(&mut b).map_err(|_| CoreError::Serialization)?;
    Ok(b)
}
fn keys(
    password: &[u8],
    salt: &[u8],
) -> Result<(
    DecapsulationKey1024,
    SigningKey<MlDsa87>,
    Zeroizing<Vec<u8>>,
)> {
    if password.len() < 12 || password.len() > 1024 || salt.len() != 32 {
        return Err(fail());
    }
    let mut material = Zeroizing::new(vec![0u8; 128]);
    Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(65536, 3, 1, Some(128)).map_err(|_| fail())?,
    )
    .hash_password_into(password, salt, &mut material)
    .map_err(|_| fail())?;
    let mut seed = ml_kem::Seed::default();
    seed.copy_from_slice(&material[..64]);
    let kem = DecapsulationKey1024::from_seed(seed);
    seed.zeroize();
    let mut seed = ml_dsa::Seed::default();
    seed.copy_from_slice(&material[64..96]);
    let signing = SigningKey::<MlDsa87>::from_seed(&seed);
    seed.zeroize();
    Ok((kem, signing, material))
}
fn aead_key(material: &[u8], shared: &[u8]) -> Zeroizing<Vec<u8>> {
    // Fixed-length, domain-separated hybrid input; not a password hash substitute.
    let mut h = Sha256::new();
    h.update(b"kaspire-vault-recovery-aead-v1\0");
    h.update(&material[96..128]);
    h.update(shared);
    Zeroizing::new(h.finalize().to_vec())
}
fn message(e: &Envelope) -> Result<Vec<u8>> {
    serde_json::to_vec(&(
        &e.format,
        &e.salt,
        &e.nonce,
        &e.kem_ciphertext,
        &e.ciphertext,
    ))
    .map_err(|_| fail())
}
pub fn validate_record(raw: &str) -> Result<Value> {
    if raw.len() > 128 * 1024 {
        return Err(fail());
    }
    let record: Value = serde_json::from_str(raw).map_err(|_| fail())?;
    if record["protocol"] != crate::covenant_vault::PROTOCOL {
        return Err(fail());
    }
    let terms: crate::covenant_vault::Terms =
        serde_json::from_value(record["terms"].clone()).map_err(|_| fail())?;
    let expected = crate::covenant_vault::descriptor(&terms)?;
    for f in [
        "vaultAddress",
        "redeemScript",
        "scriptPublicKey",
        "templateHash",
        "compiler",
    ] {
        if record[f] != expected[f] {
            return Err(fail());
        }
    }
    for f in ["covenantId", "transactionId"] {
        let s = record[f].as_str().ok_or_else(fail)?;
        if s.len() != 64 || hex::decode(s).is_err() {
            return Err(fail());
        }
    }
    if record["index"] != 0
        || record["amountSompi"]
            .as_u64()
            .is_none_or(|v| !(100_000_000..=2_870_000_000_000_000_000).contains(&v))
    {
        return Err(fail());
    }
    if !["pending", "locked", "opening", "opened"]
        .contains(&record["status"].as_str().ok_or_else(fail)?)
    {
        return Err(fail());
    }
    if !record["genesisTransactionId"].is_null() {
        let id = record["genesisTransactionId"].as_str().ok_or_else(fail)?;
        if id.len() != 64 || hex::decode(id).is_err() {
            return Err(fail());
        }
    }
    // Whitelist public recovery metadata; never accept a secret hidden in extras.
    let fields = [
        "protocol",
        "compiler",
        "terms",
        "vaultAddress",
        "redeemScript",
        "scriptPublicKey",
        "templateHash",
        "covenantId",
        "amountSompi",
        "transactionId",
        "index",
        "status",
        "genesisTransactionId",
        "lastConfirmedCell",
    ];
    if record
        .as_object()
        .ok_or_else(fail)?
        .keys()
        .any(|k| !fields.contains(&k.as_str()))
    {
        return Err(fail());
    }
    if !record["lastConfirmedCell"].is_null() {
        let cell: crate::covenant_vault::Cell =
            serde_json::from_value(record["lastConfirmedCell"].clone()).map_err(|_| fail())?;
        if cell.covenant_id != record["covenantId"].as_str().ok_or_else(fail)?
            || cell.script_public_key != record["scriptPublicKey"].as_str().ok_or_else(fail)?
            || cell.value_sompi != record["amountSompi"].as_u64().ok_or_else(fail)?
            || cell.index != 0
            || cell.block_daa_score == 0
            || cell.transaction_id.len() != 64
            || hex::decode(&cell.transaction_id).is_err()
        {
            return Err(fail());
        }
    }
    Ok(record)
}
pub fn seal(password: &[u8], record: &str) -> Result<String> {
    let record = validate_record(record)?;
    let salt = random::<32>()?;
    let nonce = random::<24>()?;
    let (kem, signing, material) = keys(password, &salt)?;
    let mut randomness = ml_kem::B32::from(random::<32>()?);
    let (ct, mut shared) = kem
        .encapsulation_key()
        .encapsulate_deterministic(&randomness);
    randomness.zeroize();
    let key = aead_key(&material, &shared);
    shared.zeroize();
    let mut e = Envelope {
        format: FORMAT.into(),
        salt: hex::encode(salt),
        nonce: hex::encode(nonce),
        kem_ciphertext: hex::encode(ct),
        ciphertext: String::new(),
        signature: String::new(),
    };
    let aad = serde_json::to_vec(&(&e.format, &e.salt, &e.nonce, &e.kem_ciphertext))
        .map_err(|_| fail())?;
    let plaintext = Zeroizing::new(serde_json::to_vec(&record).map_err(|_| fail())?);
    e.ciphertext = hex::encode(
        XChaCha20Poly1305::new_from_slice(&key)
            .map_err(|_| fail())?
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| fail())?,
    );
    let signature: Signature<MlDsa87> = signing.sign(&message(&e)?);
    e.signature = hex::encode(signature.encode());
    serde_json::to_string(&e).map_err(|_| fail())
}
pub fn open(password: &[u8], raw: &str) -> Result<String> {
    if raw.len() > 512 * 1024 {
        return Err(fail());
    }
    let e: Envelope = serde_json::from_str(raw).map_err(|_| fail())?;
    if e.format != FORMAT
        || e.nonce.len() != 48
        || e.kem_ciphertext.len() != 3136
        || e.signature.len() != 9254
        || e.ciphertext.len() > 256 * 1024 + 32
    {
        return Err(fail());
    }
    let salt = hex::decode(&e.salt).map_err(|_| fail())?;
    let (kem, signing, material) = keys(password, &salt)?;
    let signature =
        Signature::<MlDsa87>::try_from(hex::decode(&e.signature).map_err(|_| fail())?.as_slice())
            .map_err(|_| fail())?;
    // Verify against the PASSWORD-DERIVED identity, never an attacker-supplied key.
    signing
        .verifying_key()
        .verify(&message(&e)?, &signature)
        .map_err(|_| fail())?;
    let ct = Ciphertext::<MlKem1024>::try_from(
        hex::decode(&e.kem_ciphertext)
            .map_err(|_| fail())?
            .as_slice(),
    )
    .map_err(|_| fail())?;
    let mut shared = kem.decapsulate(&ct);
    let key = aead_key(&material, &shared);
    shared.zeroize();
    let nonce = hex::decode(&e.nonce).map_err(|_| fail())?;
    let aad = serde_json::to_vec(&(&e.format, &e.salt, &e.nonce, &e.kem_ciphertext))
        .map_err(|_| fail())?;
    let plaintext = Zeroizing::new(
        XChaCha20Poly1305::new_from_slice(&key)
            .map_err(|_| fail())?
            .decrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &hex::decode(e.ciphertext).map_err(|_| fail())?,
                    aad: &aad,
                },
            )
            .map_err(|_| fail())?,
    );
    let text = std::str::from_utf8(&plaintext).map_err(|_| fail())?;
    validate_record(text)?;
    Ok(text.into())
}
