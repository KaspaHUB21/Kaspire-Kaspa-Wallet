use crate::{derive_key_at_path, private_key_bytes, CoreError, Result};
use rlp::RlpStream;
use secp256k1::{Message, PublicKey, SecretKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tiny_keccak::{Hasher, Keccak};
use zeroize::Zeroizing;

const EVM_PATH: &str = "m/44'/60'/0'/0/0";
const KASPLEX_CHAIN_ID: u64 = 202_555;
const IGRA_CHAIN_ID: u64 = 38_833;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvmTransactionRequest {
    pub wallet_address: String,
    pub from: String,
    pub to: String,
    pub recipient: String,
    pub value_wei: String,
    pub nonce: u64,
    pub gas_limit: u64,
    pub gas_price_wei: String,
    pub chain_id: u64,
    #[serde(default)]
    pub data: String,
    #[serde(default)]
    pub token_symbol: String,
    #[serde(default)]
    pub display_amount: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedEvmTransaction {
    pub from: String,
    pub to: String,
    pub recipient: String,
    pub value_wei: String,
    pub nonce: u64,
    pub gas_limit: u64,
    pub gas_price_wei: String,
    pub chain_id: u64,
    pub network: String,
    pub token_symbol: String,
    pub display_amount: String,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedEvmTransaction {
    pub raw_transaction: String,
    pub transaction_hash: String,
    pub review_hash: String,
}

fn key(secret: &str) -> Result<Zeroizing<[u8; 32]>> {
    if let Some(value) = secret.strip_prefix("private:") {
        return private_key_bytes(value).map(Zeroizing::new);
    }
    if let Some(value) = secret.strip_prefix("hd-path:") {
        let (kaspa_path, root) = value
            .split_once(':')
            .ok_or_else(|| CoreError::InvalidRequest("invalid selected HD path".into()))?;
        let components: Vec<&str> = kaspa_path.split('/').collect();
        if components.len() == 6 && components[0] == "m" &&
            components[1] == "44'" && components[2] == "111111'" {
            let evm_path = format!("m/44'/60'/{}/{}/{}", components[3], components[4], components[5]);
            return derive_key_at_path(root, &evm_path);
        }
        return derive_key_at_path(root, EVM_PATH);
    }
    derive_key_at_path(secret, EVM_PATH)
}

fn keccak(data: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    let mut hash = Keccak::v256();
    hash.update(data);
    hash.finalize(&mut output);
    output
}

pub fn derive_evm_address(secret: &str) -> Result<String> {
    let bytes = key(secret)?;
    let secret_key = SecretKey::from_slice(bytes.as_ref()).map_err(|_| CoreError::Derivation)?;
    let public =
        PublicKey::from_secret_key(secp256k1::SECP256K1, &secret_key).serialize_uncompressed();
    let digest = keccak(&public[1..]);
    Ok(format!("0x{}", hex::encode(&digest[12..])))
}

pub fn export_evm_private_key(secret: &str) -> Result<String> {
    Ok(hex::encode(key(secret)?.as_ref()))
}

fn validate(request: &EvmTransactionRequest) -> Result<()> {
    if !matches!(request.chain_id, KASPLEX_CHAIN_ID | IGRA_CHAIN_ID) {
        return Err(CoreError::InvalidRequest("unsupported EVM chain ID".into()));
    }
    for address in [&request.from, &request.to, &request.recipient] {
        let raw = address.strip_prefix("0x").unwrap_or(address);
        if raw.len() != 40 || hex::decode(raw).is_err() {
            return Err(CoreError::InvalidRequest("invalid EVM address".into()));
        }
    }
    parse_uint(&request.value_wei)?;
    parse_uint(&request.gas_price_wei)?;
    if request.gas_limit < 21_000 || request.gas_limit > 30_000_000 {
        return Err(CoreError::InvalidRequest("invalid EVM gas limit".into()));
    }
    if !request.data.is_empty() {
        let data = request.data.strip_prefix("0x").unwrap_or(&request.data);
        if data.len() % 2 != 0 || hex::decode(data).is_err() {
            return Err(CoreError::InvalidRequest(
                "invalid EVM transaction data".into(),
            ));
        }
    }
    Ok(())
}

fn review(request: &EvmTransactionRequest) -> Result<PreparedEvmTransaction> {
    validate(request)?;
    let mut prepared = PreparedEvmTransaction {
        from: request.from.to_lowercase(),
        to: request.to.to_lowercase(),
        recipient: request.recipient.to_lowercase(),
        value_wei: request.value_wei.clone(),
        nonce: request.nonce,
        gas_limit: request.gas_limit,
        gas_price_wei: request.gas_price_wei.clone(),
        chain_id: request.chain_id,
        network: if request.chain_id == KASPLEX_CHAIN_ID {
            "Kasplex"
        } else {
            "Igra"
        }
        .into(),
        token_symbol: request.token_symbol.clone(),
        display_amount: request.display_amount.clone(),
        review_hash: String::new(),
    };
    let encoded = serde_json::to_vec(&prepared).map_err(|_| CoreError::Derivation)?;
    prepared.review_hash = hex::encode(Sha256::digest(encoded));
    Ok(prepared)
}

pub fn prepare_evm_transaction(request: &EvmTransactionRequest) -> Result<PreparedEvmTransaction> {
    review(request)
}

fn parse_uint(value: &str) -> Result<Vec<u8>> {
    let value = value.trim();
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(CoreError::InvalidRequest("invalid EVM integer".into()));
    }
    let mut result = vec![0u8];
    for digit in value.bytes().map(|byte| byte - b'0') {
        let mut carry = digit as u16;
        for byte in result.iter_mut().rev() {
            let next = (*byte as u16) * 10 + carry;
            *byte = next as u8;
            carry = next >> 8;
        }
        if carry != 0 {
            result.insert(0, carry as u8);
        }
    }
    while result.len() > 1 && result[0] == 0 {
        result.remove(0);
    }
    if result == [0] {
        Ok(Vec::new())
    } else {
        Ok(result)
    }
}

fn address_bytes(value: &str) -> Result<Vec<u8>> {
    hex::decode(value.strip_prefix("0x").unwrap_or(value))
        .map_err(|_| CoreError::InvalidRequest("invalid EVM address".into()))
}

fn data_bytes(value: &str) -> Result<Vec<u8>> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    hex::decode(value.strip_prefix("0x").unwrap_or(value))
        .map_err(|_| CoreError::InvalidRequest("invalid EVM data".into()))
}

fn unsigned_rlp(request: &EvmTransactionRequest) -> Result<Vec<u8>> {
    let mut stream = RlpStream::new_list(9);
    stream.append(&request.nonce);
    stream.append(&parse_uint(&request.gas_price_wei)?);
    stream.append(&request.gas_limit);
    stream.append(&address_bytes(&request.to)?);
    stream.append(&parse_uint(&request.value_wei)?);
    stream.append(&data_bytes(&request.data)?);
    stream.append(&request.chain_id);
    stream.append(&0u8);
    stream.append(&0u8);
    Ok(stream.out().to_vec())
}

pub fn sign_evm_transaction(
    secret: &str,
    request: &EvmTransactionRequest,
    review_hash: &str,
) -> Result<SignedEvmTransaction> {
    let prepared = review(request)?;
    if prepared.review_hash != review_hash {
        return Err(CoreError::InvalidRequest("EVM review hash mismatch".into()));
    }
    let derived = derive_evm_address(secret)?;
    if !derived.eq_ignore_ascii_case(&request.from) {
        return Err(CoreError::InvalidRequest(
            "EVM sender does not match the encrypted wallet".into(),
        ));
    }
    let digest = keccak(&unsigned_rlp(request)?);
    let message = Message::from_digest_slice(&digest).map_err(|_| CoreError::Derivation)?;
    let bytes = key(secret)?;
    let signing_key = SecretKey::from_slice(bytes.as_ref()).map_err(|_| CoreError::Derivation)?;
    let signature = secp256k1::SECP256K1.sign_ecdsa_recoverable(&message, &signing_key);
    let (recovery, compact) = signature.serialize_compact();
    let v = request.chain_id * 2 + 35 + recovery.to_i32() as u64;
    let mut stream = RlpStream::new_list(9);
    stream.append(&request.nonce);
    stream.append(&parse_uint(&request.gas_price_wei)?);
    stream.append(&request.gas_limit);
    stream.append(&address_bytes(&request.to)?);
    stream.append(&parse_uint(&request.value_wei)?);
    stream.append(&data_bytes(&request.data)?);
    stream.append(&v);
    stream.append(&compact[..32].to_vec());
    stream.append(&compact[32..].to_vec());
    let raw = stream.out().to_vec();
    Ok(SignedEvmTransaction {
        raw_transaction: format!("0x{}", hex::encode(&raw)),
        transaction_hash: format!("0x{}", hex::encode(keccak(&raw))),
        review_hash: prepared.review_hash,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_stable_evm_address_and_rejects_wrong_chain() {
        let secret = "mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        assert_eq!(
            derive_evm_address(secret).unwrap(),
            "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        );
        assert_eq!(
            derive_evm_address(&format!("hd-path:m/44'/111111'/0'/0/0:{}", secret)).unwrap(),
            "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        );
        assert_ne!(
            derive_evm_address(&format!("hd-path:m/44'/111111'/0'/0/1:{}", secret)).unwrap(),
            "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        );
        let request = EvmTransactionRequest {
            wallet_address: "kaspa:test".into(),
            from: derive_evm_address(secret).unwrap(),
            to: "0x0000000000000000000000000000000000000001".into(),
            recipient: "0x0000000000000000000000000000000000000001".into(),
            value_wei: "1".into(),
            nonce: 0,
            gas_limit: 21000,
            gas_price_wei: "1".into(),
            chain_id: 1,
            data: String::new(),
            token_symbol: "KAS".into(),
            display_amount: "0.000000000000000001".into(),
        };
        assert!(prepare_evm_transaction(&request).is_err());
    }
}
