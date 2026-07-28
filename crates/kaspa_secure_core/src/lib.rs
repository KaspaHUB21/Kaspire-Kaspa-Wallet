mod inscription;
mod kcc20;
mod policy_transaction;
mod pskt;
mod transaction;

#[cfg(target_os = "android")]
mod android;

use argon2::{Algorithm, Argon2, Params, Version as ArgonVersion};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_bip32::{
    DerivationPath, ExtendedPrivateKey, Language, Mnemonic, PrivateKey, SecretKey, WordCount,
};
use kaspa_hashes::PersonalMessageSigningHash;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

pub use inscription::{
    prepare_inscription, prepare_reveal, sign_reveal, InscriptionPlan, InscriptionRequest,
    PreparedReveal, RevealRequest, SignedReveal,
};
pub use kcc20::{
    kcc20_template_hash, prepare_kcc20_transfer, sign_kcc20_transfer, Kcc20Cell,
    Kcc20TransferRequest, PreparedKcc20Transfer, SignedKcc20Transfer,
};
pub use policy_transaction::{
    prepare_policy_transaction, sign_policy_transaction, PolicyTransactionRequest,
    PreparedPolicyTransaction, SignedPolicyTransaction,
};
pub use pskt::{
    prepare_pskt, sign_pskt, PreparedPskt, PsktInputReview, PsktOutputReview, PsktRequest,
    PsktSignInput, SignedPskt,
};
pub use transaction::{
    prepare_transaction, sign_transaction, PreparedTransaction, SendRequest, SignedTransaction,
};

pub const REQUIRED_RUSTY_KASPA_RELEASE: &str = "v2.0.1";
pub const DERIVATION_PATH: &str = "m/44'/111111'/0'/0/0";
pub const MODERN_COIN_TYPE: u32 = 111_111;
pub const LEGACY_COIN_TYPE: u32 = 972;
pub const BACKUP_ARGON2_MEMORY_KIB: u32 = 32_768;
pub const BACKUP_ARGON2_ITERATIONS: u32 = 3;
pub const BACKUP_ARGON2_PARALLELISM: u32 = 1;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("invalid mnemonic: enter 12 or 24 valid English BIP39 words")]
    InvalidMnemonic,
    #[error("invalid private key: enter exactly 64 hexadecimal characters")]
    InvalidPrivateKey,
    #[error("invalid Kaspa address")]
    InvalidAddress,
    #[error("wallet derivation failed")]
    Derivation,
    #[error("invalid transaction request: {0}")]
    InvalidRequest(String),
    #[error("untrusted UTXO data: {0}")]
    UntrustedUtxo(String),
    #[error("insufficient mature funds")]
    InsufficientFunds,
    #[error("transaction generation failed: {0}")]
    Transaction(String),
    #[error("approved review does not match the transaction")]
    ReviewMismatch,
    #[error("serialization failed")]
    Serialization,
}

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct WalletMaterial {
    pub mnemonic: String,
    pub address: String,
    pub derivation_path: String,
}

#[derive(Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct PrivateKeyMaterial {
    pub private_key: String,
    pub address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HdAddress {
    pub address: String,
    pub derivation_path: String,
    pub coin_type: u32,
    pub account: u32,
    pub change: u32,
    pub index: u32,
}

pub fn derive_address_range(
    secret: &str,
    coin_type: u32,
    account: u32,
    change: u32,
    start: u32,
    count: u32,
) -> Result<Vec<HdAddress>> {
    if !matches!(coin_type, MODERN_COIN_TYPE | LEGACY_COIN_TYPE)
        || account > 100
        || change > 1
        || count == 0
        || count > 100
        || start.checked_add(count).is_none()
    {
        return Err(CoreError::InvalidRequest(
            "invalid HD discovery range".into(),
        ));
    }
    if secret.starts_with("private:") {
        let address = derive_address(secret)?;
        return Ok(
            if start == 0 && coin_type == MODERN_COIN_TYPE && change == 0 {
                vec![HdAddress {
                    address: address.to_string(),
                    derivation_path: "private-key".into(),
                    coin_type,
                    account,
                    change,
                    index: 0,
                }]
            } else {
                vec![]
            },
        );
    }
    (start..start + count)
        .map(|index| {
            let path = hd_path(coin_type, account, change, index);
            let key = derive_key_at_path(secret, &path)?;
            Ok(HdAddress {
                address: address_from_key(&key)?.to_string(),
                derivation_path: path,
                coin_type,
                account,
                change,
                index,
            })
        })
        .collect()
}

pub fn generate_wallet() -> Result<WalletMaterial> {
    generate_wallet_with_passphrase("")
}

pub fn generate_wallet_with_passphrase(passphrase: &str) -> Result<WalletMaterial> {
    let mnemonic = Mnemonic::random(WordCount::Words24, Language::English)
        .map_err(|_| CoreError::Derivation)?;
    wallet_material(mnemonic, passphrase)
}

pub fn derive_backup_key(password: &str, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    if password.len() < 12 || salt.len() != 32 {
        return Err(CoreError::InvalidRequest(
            "backup password or salt is invalid".into(),
        ));
    }
    let params = Params::new(
        BACKUP_ARGON2_MEMORY_KIB,
        BACKUP_ARGON2_ITERATIONS,
        BACKUP_ARGON2_PARALLELISM,
        Some(32),
    )
    .map_err(|_| CoreError::Derivation)?;
    let argon = Argon2::new(Algorithm::Argon2id, ArgonVersion::V0x13, params);
    let mut key = Zeroizing::new([0u8; 32]);
    argon
        .hash_password_into(password.as_bytes(), salt, key.as_mut())
        .map_err(|_| CoreError::Derivation)?;
    Ok(key)
}

pub fn import_wallet(phrase: &str) -> Result<WalletMaterial> {
    import_wallet_with_passphrase(phrase, "")
}

pub fn import_wallet_with_passphrase(phrase: &str, passphrase: &str) -> Result<WalletMaterial> {
    let normalized = normalize_mnemonic(phrase);
    let mnemonic =
        Mnemonic::new(normalized, Language::English).map_err(|_| CoreError::InvalidMnemonic)?;
    wallet_material(mnemonic, passphrase)
}

pub fn import_private_key(value: &str) -> Result<PrivateKeyMaterial> {
    let private_key = normalize_private_key(value)?;
    let bytes = private_key_bytes(&private_key)?;
    Ok(PrivateKeyMaterial {
        address: address_from_key(&bytes)?.to_string(),
        private_key,
    })
}

pub fn export_private_key(secret: &str) -> Result<String> {
    Ok(hex::encode(derive_key(secret)?.as_ref()))
}

pub fn sign_personal_message(secret: &str, address: &str, message: &str) -> Result<String> {
    if message.as_bytes().len() > 4096 {
        return Err(CoreError::InvalidRequest(
            "personal message exceeds 4096 UTF-8 bytes".into(),
        ));
    }
    if derive_address(secret)?.to_string() != address {
        return Err(CoreError::InvalidRequest(
            "key does not control requested message-signing address".into(),
        ));
    }
    let mut hasher = PersonalMessageSigningHash::new();
    hasher.write(message.as_bytes());
    let digest = hasher.finalize();
    let message = secp256k1::Message::from_digest_slice(digest.as_slice())
        .map_err(|_| CoreError::Derivation)?;
    let key = derive_key(secret)?;
    let keypair = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, key.as_ref())
        .map_err(|_| CoreError::Derivation)?;
    Ok(hex::encode(keypair.sign_schnorr(message).as_ref()))
}

fn normalize_mnemonic(phrase: &str) -> String {
    phrase
        .split_whitespace()
        .filter_map(|part| {
            let word = part
                .trim_matches(|character: char| character == ',' || character == ';')
                .trim_start_matches(|character: char| character.is_ascii_digit())
                .trim_start_matches(|character: char| matches!(character, '.' | ')' | ':' | '-'))
                .trim_matches(|character: char| character == ',' || character == ';');
            (!word.is_empty()).then(|| word.to_lowercase())
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn wallet_material(mnemonic: Mnemonic, passphrase: &str) -> Result<WalletMaterial> {
    let address = derive_address_from_mnemonic(&mnemonic, passphrase)?;
    Ok(WalletMaterial {
        mnemonic: mnemonic.phrase_string(),
        address: address.to_string(),
        derivation_path: DERIVATION_PATH.to_string(),
    })
}

pub(crate) fn derive_key(phrase: &str) -> Result<Zeroizing<[u8; 32]>> {
    if let Some(value) = phrase.strip_prefix("private:") {
        return private_key_bytes(value).map(Zeroizing::new);
    }
    let (selected_path, secret) = selected_hd_path(phrase);
    derive_key_at_path(secret, selected_path.unwrap_or(DERIVATION_PATH))
}

fn derive_key_at_path(secret: &str, path: &str) -> Result<Zeroizing<[u8; 32]>> {
    let (phrase, passphrase) = mnemonic_secret(secret)?;
    let mnemonic = Mnemonic::new(
        phrase.split_whitespace().collect::<Vec<_>>().join(" "),
        Language::English,
    )
    .map_err(|_| CoreError::InvalidMnemonic)?;
    let seed = mnemonic.to_seed(passphrase.as_str());
    let master =
        ExtendedPrivateKey::<SecretKey>::new(seed.as_bytes()).map_err(|_| CoreError::Derivation)?;
    let path = DerivationPath::from_str(path).map_err(|_| CoreError::Derivation)?;
    let mut key = master
        .derive_path(&path)
        .map_err(|_| CoreError::Derivation)?
        .private_key()
        .to_bytes();
    let result = Zeroizing::new(key);
    key.zeroize();
    Ok(result)
}

fn hd_path(coin_type: u32, account: u32, change: u32, index: u32) -> String {
    format!("m/44'/{coin_type}'/{account}'/{change}/{index}")
}

fn selected_hd_path(secret: &str) -> (Option<&str>, &str) {
    secret
        .strip_prefix("hd-path:")
        .and_then(|value| value.split_once(':'))
        .map_or((None, secret), |(path, base)| (Some(path), base))
}

fn normalize_private_key(value: &str) -> Result<String> {
    let normalized = value.trim().strip_prefix("0x").unwrap_or(value.trim());
    if normalized.len() != 64 || !normalized.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(CoreError::InvalidPrivateKey);
    }
    private_key_bytes(normalized)?;
    Ok(normalized.to_lowercase())
}

fn private_key_bytes(value: &str) -> Result<[u8; 32]> {
    let decoded = hex::decode(value).map_err(|_| CoreError::InvalidPrivateKey)?;
    let bytes: [u8; 32] = decoded
        .try_into()
        .map_err(|_| CoreError::InvalidPrivateKey)?;
    SecretKey::from_bytes(&bytes).map_err(|_| CoreError::InvalidPrivateKey)?;
    Ok(bytes)
}

pub(crate) fn derive_address(phrase: &str) -> Result<Address> {
    let key = derive_key(phrase)?;
    address_from_key(&key)
}

fn mnemonic_secret(secret: &str) -> Result<(Zeroizing<String>, Zeroizing<String>)> {
    if let Some(encoded) = secret.strip_prefix("mnemonic-passphrase:") {
        let (passphrase_hex, phrase) = encoded
            .split_once(':')
            .ok_or_else(|| CoreError::InvalidRequest("invalid passphrase wallet secret".into()))?;
        let passphrase = hex::decode(passphrase_hex)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .ok_or_else(|| CoreError::InvalidRequest("invalid passphrase wallet secret".into()))?;
        return Ok((
            Zeroizing::new(phrase.to_string()),
            Zeroizing::new(passphrase),
        ));
    }
    Ok((
        Zeroizing::new(
            secret
                .strip_prefix("mnemonic:")
                .unwrap_or(secret)
                .to_string(),
        ),
        Zeroizing::new(String::new()),
    ))
}

fn derive_address_from_mnemonic(mnemonic: &Mnemonic, passphrase: &str) -> Result<Address> {
    let phrase = Zeroizing::new(mnemonic.phrase_string());
    let secret = Zeroizing::new(if passphrase.is_empty() {
        format!("mnemonic:{}", phrase.as_str())
    } else {
        format!(
            "mnemonic-passphrase:{}:{}",
            hex::encode(passphrase),
            phrase.as_str()
        )
    });
    derive_address(&secret)
}

fn address_from_key(key: &[u8; 32]) -> Result<Address> {
    let secret = SecretKey::from_bytes(key).map_err(|_| CoreError::Derivation)?;
    let secp = kaspa_bip32::secp256k1::Secp256k1::new();
    let public = secret.public_key(&secp).serialize();
    Ok(Address::new(Prefix::Mainnet, Version::PubKey, &public[1..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VECTOR: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn argon2_backup_key_is_deterministic_and_password_bound() {
        let salt = [7u8; 32];
        let first = derive_backup_key("correct horse battery staple", &salt).unwrap();
        let second = derive_backup_key("correct horse battery staple", &salt).unwrap();
        let different = derive_backup_key("correct horse battery staples", &salt).unwrap();
        assert_eq!(first.as_slice(), second.as_slice());
        assert_ne!(first.as_slice(), different.as_slice());
    }

    #[test]
    fn creates_24_word_wallet() {
        let wallet = generate_wallet().unwrap();
        assert_eq!(wallet.mnemonic.split_whitespace().count(), 24);
        assert!(wallet.address.starts_with("kaspa:"));
        assert_eq!(wallet.derivation_path, DERIVATION_PATH);
    }

    #[test]
    fn import_is_deterministic() {
        let one = import_wallet(VECTOR).unwrap();
        let two = import_wallet(VECTOR).unwrap();
        assert_eq!(one.address, two.address);
        // Cross-checked against the official v2.0.1 WASM SDK PrivateKeyGenerator.
        assert_eq!(
            one.address,
            "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh"
        );
    }

    #[test]
    fn passphrase_creates_a_distinct_deterministic_wallet() {
        let standard = import_wallet(VECTOR).unwrap();
        let protected_one = import_wallet_with_passphrase(VECTOR, "TREZOR").unwrap();
        let protected_two = import_wallet_with_passphrase(VECTOR, "TREZOR").unwrap();
        assert_ne!(standard.address, protected_one.address);
        assert_eq!(protected_one.address, protected_two.address);

        let secret = format!("mnemonic-passphrase:{}:{VECTOR}", hex::encode("TREZOR"));
        assert_eq!(
            derive_address(&secret).unwrap().to_string(),
            protected_one.address
        );
        assert_ne!(
            import_wallet_with_passphrase(VECTOR, "trezor")
                .unwrap()
                .address,
            protected_one.address
        );
    }

    #[test]
    fn derives_modern_and_legacy_hd_ranges_and_selected_paths() {
        let secret = format!("mnemonic:{VECTOR}");
        let modern = derive_address_range(&secret, MODERN_COIN_TYPE, 0, 0, 0, 3).unwrap();
        let legacy = derive_address_range(&secret, LEGACY_COIN_TYPE, 0, 0, 0, 1).unwrap();
        assert_eq!(modern.len(), 3);
        assert_eq!(modern[0].derivation_path, DERIVATION_PATH);
        assert_ne!(modern[0].address, modern[1].address);
        assert_ne!(modern[0].address, legacy[0].address);
        assert_eq!(
            derive_address(&format!("hd-path:{}:{}", modern[2].derivation_path, secret))
                .unwrap()
                .to_string(),
            modern[2].address
        );
    }

    #[test]
    fn rejects_invalid_mnemonic() {
        assert!(matches!(
            import_wallet("not a seed"),
            Err(CoreError::InvalidMnemonic)
        ));
    }

    #[test]
    fn imports_numbered_multiline_mnemonic() {
        let numbered = "1. abandon 2. abandon 3. abandon 4. abandon 5. abandon 6. abandon\n7. abandon 8. abandon 9. abandon 10. abandon 11. abandon 12. about";
        assert_eq!(
            import_wallet(numbered).unwrap().address,
            import_wallet(VECTOR).unwrap().address
        );
    }

    #[test]
    fn imports_and_exports_private_key() {
        let private_key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        let wallet = import_private_key(private_key).unwrap();
        assert!(wallet.address.starts_with("kaspa:"));
        assert_eq!(
            export_private_key(&format!("private:{private_key}")).unwrap(),
            private_key
        );
        assert!(matches!(
            import_private_key("not-a-private-key"),
            Err(CoreError::InvalidPrivateKey)
        ));
    }

    #[test]
    fn signs_kip5_personal_message_for_controlling_address() {
        let private_key = "0000000000000000000000000000000000000000000000000000000000000003";
        let wallet = import_private_key(private_key).unwrap();
        let signature = sign_personal_message(
            &format!("private:{private_key}"),
            &wallet.address,
            "Hello Kaspa!",
        )
        .unwrap();
        assert_eq!(signature.len(), 128);
        assert!(sign_personal_message(
            &format!("private:{private_key}"),
            "kaspa:qinvalid",
            "Hello Kaspa!",
        )
        .is_err());
    }

    #[test]
    fn exports_derived_private_key_from_mnemonic() {
        let private_key = export_private_key(&format!("mnemonic:{VECTOR}")).unwrap();
        assert_eq!(private_key.len(), 64);
        let imported = import_private_key(&private_key).unwrap();
        assert_eq!(imported.address, import_wallet(VECTOR).unwrap().address);
    }

    #[test]
    fn exports_the_private_key_for_the_selected_hd_subwallet() {
        let root_secret = format!("mnemonic:{VECTOR}");
        let selected_path = "m/44'/111111'/0'/0/2";
        let selected_secret = format!("hd-path:{selected_path}:{root_secret}");
        let primary_key = export_private_key(&root_secret).unwrap();
        let selected_key = export_private_key(&selected_secret).unwrap();
        assert_ne!(selected_key, primary_key);

        let selected_address =
            derive_address_range(&root_secret, MODERN_COIN_TYPE, 0, 0, 2, 1)
                .unwrap()
                .remove(0)
                .address;
        assert_eq!(
            import_private_key(&selected_key).unwrap().address,
            selected_address
        );
    }

    #[test]
    fn prepares_signs_and_binds_review() {
        let wallet = import_wallet(VECTOR).unwrap();
        let address = Address::try_from(wallet.address.as_str()).unwrap();
        let script = hex::encode(kaspa_txscript::pay_to_address_script(&address).script());
        let utxos = serde_json::json!([{
            "address": wallet.address,
            "outpoint": {"transactionId": "1111111111111111111111111111111111111111111111111111111111111111", "index": 0},
            "utxoEntry": {"amount": "100000000", "scriptPublicKey": {"scriptPublicKey": script}, "blockDaaScore": "100", "isCoinbase": false}
        }]).to_string();
        let request = SendRequest {
            sender: wallet.address.clone(),
            recipient: wallet.address.clone(),
            amount_sompi: 10_000_000,
            fee_rate: 1.0,
            utxos_json: utxos,
            send_all: false,
        };
        let prepared = prepare_transaction(&request).unwrap();
        assert_eq!(prepared.amount_sompi, 10_000_000);
        assert!(prepared.fee_sompi > 0);
        assert_eq!(prepared.input_count, 1);
        assert_eq!(prepared.output_count, 2);
        assert!(matches!(
            sign_transaction(VECTOR, &request, "wrong"),
            Err(CoreError::ReviewMismatch)
        ));
        let signed = sign_transaction(VECTOR, &request, &prepared.review_hash).unwrap();
        let submit: serde_json::Value = serde_json::from_str(&signed.submit_json).unwrap();
        let signature = submit["transaction"]["inputs"][0]["signatureScript"]
            .as_str()
            .unwrap();
        assert_eq!(signature.len(), 132);

        let send_all = SendRequest {
            amount_sompi: 0,
            send_all: true,
            ..request
        };
        let max = prepare_transaction(&send_all).unwrap();
        assert_eq!(max.change_sompi, 0);
        assert_eq!(max.output_count, 1);
        assert_eq!(max.amount_sompi + max.fee_sompi, max.total_input_sompi);
        assert!(sign_transaction(VECTOR, &send_all, &max.review_hash).is_ok());
    }
}
