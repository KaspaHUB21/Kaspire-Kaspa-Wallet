// Same wallet-secret parsing and zeroizing BIP32 derivation as the existing wallet core.
use kaspa_addresses::{Address,Prefix,Version};
use kaspa_bip32::{DerivationPath,ExtendedPrivateKey,Language,Mnemonic,PrivateKey};
use std::str::FromStr;
use thiserror::Error;
use zeroize::{Zeroize,Zeroizing};
use crate::secret_input::ErasedKey;
pub const DERIVATION_PATH:&str="m/44'/111111'/0'/0/0";
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
pub fn public_key(secret: &str) -> Result<String> {
    let key = derive_key(secret)?;
    let secret = ErasedKey::from_bytes(&*key).map_err(|_| CoreError::Derivation)?;
    let secp = kaspa_bip32::secp256k1::Secp256k1::new();
    let serialized = secret.0.public_key(&secp).serialize();
    Ok(hex::encode(&serialized[1..]))
}

pub(crate) fn controls_address(secret: &str, address: &str) -> Result<bool> {
    let requested = Address::try_from(address).map_err(|_| CoreError::InvalidAddress)?;
    if !matches!(requested.prefix, Prefix::Mainnet | Prefix::Testnet) {
        return Ok(false);
    }
    let derived = derive_address(secret)?;
    Ok(derived.version == requested.version && derived.payload == requested.payload)
}

pub(crate) fn derive_key(phrase: &str) -> Result<Zeroizing<[u8; 32]>> {
    if let Some(value) = phrase.strip_prefix("private:") {
        return private_key_bytes(value).map(Zeroizing::new);
    }
    let (selected_path, secret) = selected_hd_path(phrase);
    derive_key_at_path(secret, selected_path.unwrap_or(DERIVATION_PATH))
}

pub(crate) fn derive_key_at_path(secret: &str, path: &str) -> Result<Zeroizing<[u8; 32]>> {
    let (phrase, passphrase) = mnemonic_secret(secret)?;
    let normalized = Zeroizing::new(phrase.split_whitespace().collect::<Vec<_>>().join(" "));
    let mnemonic = Mnemonic::new(normalized.as_str(), Language::English)
    .map_err(|_| CoreError::InvalidMnemonic)?;
    let seed = mnemonic.to_seed(passphrase.as_str());
    let master =
        ExtendedPrivateKey::<ErasedKey>::new(seed.as_bytes()).map_err(|_| CoreError::Derivation)?;
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

fn selected_hd_path(secret: &str) -> (Option<&str>, &str) {
    secret
        .strip_prefix("hd-path:")
        .and_then(|value| value.split_once(':'))
        .map_or((None, secret), |(path, base)| (Some(path), base))
}

pub(crate) fn private_key_bytes(value: &str) -> Result<[u8; 32]> {
    let decoded = hex::decode(value).map_err(|_| CoreError::InvalidPrivateKey)?;
    let bytes: [u8; 32] = decoded
        .try_into()
        .map_err(|_| CoreError::InvalidPrivateKey)?;
    ErasedKey::from_bytes(&bytes).map_err(|_| CoreError::InvalidPrivateKey)?;
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
        let passphrase_bytes = Zeroizing::new(hex::decode(passphrase_hex)
            .map_err(|_| CoreError::InvalidRequest("invalid passphrase wallet secret".into()))?);
        let passphrase = Zeroizing::new(std::str::from_utf8(&passphrase_bytes)
            .map_err(|_| CoreError::InvalidRequest("invalid passphrase wallet secret".into()))?
            .to_owned());
        return Ok((
            Zeroizing::new(phrase.to_string()),
            passphrase,
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

fn address_from_key(key: &[u8; 32]) -> Result<Address> {
    let secret = ErasedKey::from_bytes(key).map_err(|_| CoreError::Derivation)?;
    let secp = kaspa_bip32::secp256k1::Secp256k1::new();
    let public = secret.0.public_key(&secp).serialize();
    Ok(Address::new(Prefix::Mainnet, Version::PubKey, &public[1..]))
}
