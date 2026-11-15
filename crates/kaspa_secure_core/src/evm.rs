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
        if components.len() == 6
            && components[0] == "m"
            && components[1] == "44'"
            && components[2] == "111111'"
        {
            let evm_path = format!(
                "m/44'/60'/{}/{}/{}",
                components[3], components[4], components[5]
            );
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

// secp256k1 compact signatures use fixed-width scalars. Ethereum RLP encodes
// r and s as integers, whose representation must not contain leading zeroes.
fn scalar_rlp_bytes(value: &[u8]) -> &[u8] {
    &value[value
        .iter()
        .position(|byte| *byte != 0)
        .unwrap_or(value.len())..]
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
    stream.append(&scalar_rlp_bytes(&compact[..32]));
    stream.append(&scalar_rlp_bytes(&compact[32..]));
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

    fn transfer(chain_id: u64, nonce: u64) -> (String, EvmTransactionRequest) {
        let secret = format!("private:{}", "42".repeat(32));
        let request = EvmTransactionRequest {
            wallet_address: "kaspa:fixture".into(),
            from: derive_evm_address(&secret).unwrap(),
            to: format!("0x{}", "22".repeat(20)),
            recipient: format!("0x{}", "22".repeat(20)),
            value_wei: "1".into(),
            nonce,
            gas_limit: 21_000,
            gas_price_wei: "2000000000000".into(),
            chain_id,
            data: String::new(),
            token_symbol: "iKAS".into(),
            display_amount: "0.000000000000000001".into(),
        };
        (secret, request)
    }

    #[test]
    fn igra_leading_zero_signature_regression() {
        let (secret, request) = transfer(IGRA_CHAIN_ID, 83);
        let prepared = prepare_evm_transaction(&request).unwrap();
        let signed = sign_evm_transaction(&secret, &request, &prepared.review_hash).unwrap();
        // Old code emits a0002157... (32-byte string with a leading zero).
        // The valid integer encoding is 9f2157... (31 bytes).
        assert_eq!(signed.raw_transaction, "0xf867538601d1a94a2000825208942222222222222222222222222222222222222222018083012f86a087f6a5ca0a4ed16e5cde799ab9dab7bcb57ecf65f8922c3be823a7453a860d329f2157f6b4827ec6494bf2d0c1c0358628c5794f833f92c38bba728037277cb8");
    }

    #[test]
    fn signatures_are_canonical_and_recover_sender_on_both_supported_chains() {
        use secp256k1::ecdsa::{RecoverableSignature, RecoveryId};
        for chain in [IGRA_CHAIN_ID, KASPLEX_CHAIN_ID] {
            let mut short_r = false;
            let mut short_s = false;
            for nonce in 0..1024 {
                let (secret, request) = transfer(chain, nonce);
                let prepared = prepare_evm_transaction(&request).unwrap();
                let signed =
                    sign_evm_transaction(&secret, &request, &prepared.review_hash).unwrap();
                let bytes = hex::decode(&signed.raw_transaction[2..]).unwrap();
                assert!(
                    bytes[0] >= 0xc0,
                    "legacy transactions have no type-0 prefix"
                );
                let tx = rlp::Rlp::new(&bytes);
                assert_eq!(tx.item_count().unwrap(), 9);
                let r = tx.at(7).unwrap().data().unwrap();
                let s = tx.at(8).unwrap().data().unwrap();
                assert!(!r.is_empty() && r.len() <= 32 && r[0] != 0);
                assert!(!s.is_empty() && s.len() <= 32 && s[0] != 0);
                short_r |= r.len() < 32;
                short_s |= s.len() < 32;
                let v: u64 = tx.val_at(6).unwrap();
                assert!([chain * 2 + 35, chain * 2 + 36].contains(&v));
                let mut compact = [0u8; 64];
                compact[32 - r.len()..32].copy_from_slice(r);
                compact[64 - s.len()..].copy_from_slice(s);
                let recovery = RecoveryId::from_i32((v - chain * 2 - 35) as i32).unwrap();
                let signature = RecoverableSignature::from_compact(&compact, recovery).unwrap();
                let message =
                    Message::from_digest_slice(&keccak(&unsigned_rlp(&request).unwrap())).unwrap();
                let public = secp256k1::SECP256K1
                    .recover_ecdsa(&message, &signature)
                    .unwrap()
                    .serialize_uncompressed();
                assert_eq!(
                    format!("0x{}", hex::encode(&keccak(&public[1..])[12..])),
                    request.from
                );
                assert_eq!(
                    signed.transaction_hash,
                    format!("0x{}", hex::encode(keccak(&bytes)))
                );
            }
            assert!(
                short_r && short_s,
                "exercise both leading-zero scalar cases"
            );
        }
    }

    #[test]
    fn eip155_reference_signing_payload_is_unchanged() {
        let (_, mut request) = transfer(1, 9);
        request.to = format!("0x{}", "35".repeat(20));
        request.gas_price_wei = "20000000000".into();
        request.value_wei = "1000000000000000000".into();
        let bytes = unsigned_rlp(&request).unwrap();
        assert_eq!(hex::encode(&bytes), "ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080");
        assert_eq!(
            hex::encode(keccak(&bytes)),
            "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53"
        );
        assert!(
            prepare_evm_transaction(&request).is_err(),
            "reference vector does not authorize Ethereum mainnet"
        );
    }

    #[test]
    fn erc20_calldata_and_authorization_remain_bound_to_review() {
        let (secret, mut request) = transfer(IGRA_CHAIN_ID, 83);
        request.value_wei = "0".into();
        request.gas_limit = 65_000;
        request.data = format!("0xa9059cbb{}{}", "00".repeat(32), "00".repeat(31) + "01");
        let prepared = prepare_evm_transaction(&request).unwrap();
        let signed = sign_evm_transaction(&secret, &request, &prepared.review_hash).unwrap();
        let bytes = hex::decode(&signed.raw_transaction[2..]).unwrap();
        let tx = rlp::Rlp::new(&bytes);
        assert_eq!(
            tx.at(5).unwrap().data().unwrap(),
            data_bytes(&request.data).unwrap()
        );
        assert_eq!(tx.at(4).unwrap().data().unwrap(), &[] as &[u8]);
        let mut changed = request.clone();
        changed.value_wei = "1".into();
        assert!(sign_evm_transaction(&secret, &changed, &prepared.review_hash).is_err());
        assert!(sign_evm_transaction(
            &format!("private:{}", "43".repeat(32)),
            &request,
            &prepared.review_hash
        )
        .is_err());
        assert_eq!(scalar_rlp_bytes(&[0, 0, 1]), &[1]);
        assert!(scalar_rlp_bytes(&[0; 32]).is_empty());
    }

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
