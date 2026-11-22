//! JSON-facing types for the transaction builders (camelCase, hex bytes).
//!
//! Amounts are JSON integers. JavaScript callers must parse them without
//! rounding (above 2^53 a plain `JSON.parse` loses precision).

use std::collections::BTreeMap;

use argent_runtime::{ArtifactValue, state};
use kaspa_consensus_core::{
    Hash,
    tx::{ScriptPublicKey, TransactionId, TransactionOutpoint, UtxoEntry},
};
use serde::{Deserialize, Serialize};

use crate::hex;

pub type State = BTreeMap<String, ArtifactValue>;

pub fn bytes32(text: &str, what: &str) -> Result<[u8; 32], String> {
    let bytes = hex::decode(text).map_err(|e| format!("{what}: {e}"))?;
    bytes.try_into().map_err(|b: Vec<u8>| format!("{what}: expected 32 bytes, got {}", b.len()))
}

pub fn hash(text: &str, what: &str) -> Result<Hash, String> {
    Ok(Hash::from_bytes(bytes32(text, what)?))
}

/// Integers in requests may be JSON numbers or decimal strings: JavaScript
/// callers carry anything past 2^53 as a string. Floats are refused.
pub mod int {
    use serde::de::{Deserializer, Error, Visitor};
    use std::{fmt, marker::PhantomData, str::FromStr};

    pub trait Int: FromStr + TryFrom<u64> + TryFrom<i64> {}
    impl<T: FromStr + TryFrom<u64> + TryFrom<i64>> Int for T {}

    struct Plain<T>(PhantomData<T>);

    impl<'de, T: Int> Visitor<'de> for Plain<T> {
        type Value = T;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("an integer, as a number or a decimal string")
        }
        fn visit_u64<E: Error>(self, v: u64) -> Result<T, E> {
            T::try_from(v).map_err(|_| E::custom(format!("{v} is out of range")))
        }
        fn visit_i64<E: Error>(self, v: i64) -> Result<T, E> {
            T::try_from(v).map_err(|_| E::custom(format!("{v} is out of range")))
        }
        fn visit_str<E: Error>(self, v: &str) -> Result<T, E> {
            let digits = v.strip_prefix('-').unwrap_or(v);
            if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return Err(E::custom(format!("{v:?} is not a decimal integer")));
            }
            v.parse().map_err(|_| E::custom(format!("{v} is out of range")))
        }
    }

    pub fn de<'de, D: Deserializer<'de>, T: Int>(d: D) -> Result<T, D::Error> {
        d.deserialize_any(Plain(PhantomData))
    }

    struct Optional<T>(PhantomData<T>);

    impl<'de, T: Int> Visitor<'de> for Optional<T> {
        type Value = Option<T>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("an integer or null")
        }
        fn visit_none<E: Error>(self) -> Result<Option<T>, E> {
            Ok(None)
        }
        fn visit_unit<E: Error>(self) -> Result<Option<T>, E> {
            Ok(None)
        }
        fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Option<T>, D::Error> {
            de(d).map(Some)
        }
    }

    pub fn opt<'de, D: Deserializer<'de>, T: Int>(d: D) -> Result<Option<T>, D::Error> {
        d.deserialize_option(Optional(PhantomData))
    }
}

/// A UTXO as the node reports it, flattened.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Utxo {
    pub transaction_id: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub index: u32,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub amount: u64,
    /// Version (2 bytes, big-endian) followed by the script, in hex.
    pub script_public_key: String,
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::de")]
    pub block_daa_score: u64,
    #[serde(default)]
    pub is_coinbase: bool,
    #[serde(default)]
    pub covenant_id: Option<String>,
}

impl Utxo {
    pub fn outpoint(&self) -> Result<TransactionOutpoint, String> {
        Ok(TransactionOutpoint::new(TransactionId::from_bytes(bytes32(&self.transaction_id, "transactionId")?), self.index))
    }

    pub fn entry(&self) -> Result<UtxoEntry, String> {
        let covenant_id = match &self.covenant_id {
            Some(id) => Some(hash(id, "covenantId")?),
            None => None,
        };
        Ok(UtxoEntry::new(self.amount, spk_from_hex(&self.script_public_key)?, self.block_daa_score, self.is_coinbase, covenant_id))
    }
}

pub fn spk_from_hex(text: &str) -> Result<ScriptPublicKey, String> {
    let bytes = hex::decode(text).map_err(|e| format!("scriptPublicKey: {e}"))?;
    if bytes.len() < 2 {
        return Err("scriptPublicKey: missing the version".into());
    }
    let version = u16::from_be_bytes([bytes[0], bytes[1]]);
    Ok(ScriptPublicKey::from_vec(version, bytes[2..].to_vec()))
}

pub fn spk_to_hex(spk: &ScriptPublicKey) -> String {
    let mut bytes = spk.version().to_be_bytes().to_vec();
    bytes.extend_from_slice(spk.script());
    hex::encode(&bytes)
}

/// A plain P2PK (Schnorr) coin and the key that spends it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Funding {
    pub utxo: Utxo,
    pub secret_key: String,
}

/// A KCC-20 state (SPEC §5; KCC-20 §1).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenState {
    #[serde(deserialize_with = "crate::model::int::de")]
    pub amount: i64,
    pub owner: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub owner_scheme: u8,
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::de")]
    pub borrow_scheme: u8,
    #[serde(default = "zero32")]
    pub borrow_guard: String,
    #[serde(default = "zero32")]
    pub extension_commitment: String,
}

pub fn zero32() -> String {
    "00".repeat(32)
}

impl TokenState {
    pub fn plain(owner_scheme: u8, owner: &[u8; 32], amount: i64) -> Self {
        Self {
            amount,
            owner: hex::encode(owner),
            owner_scheme,
            borrow_scheme: 0,
            borrow_guard: zero32(),
            extension_commitment: zero32(),
        }
    }

    pub fn to_state(&self) -> Result<State, String> {
        Ok(state! {
            amount: self.amount,
            owner: bytes32(&self.owner, "owner")?.to_vec(),
            owner_scheme: self.owner_scheme,
            borrow_scheme: self.borrow_scheme,
            borrow_guard: bytes32(&self.borrow_guard, "borrowGuard")?.to_vec(),
            extension_commitment: bytes32(&self.extension_commitment, "extensionCommitment")?.to_vec()
        })
    }
}

/// BridgeMint's state (SPEC §6).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MinterState {
    #[serde(deserialize_with = "crate::model::int::de")]
    pub remaining: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub bucket: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub capacity: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub refill_per_daa: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub nonce_ethereum: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub nonce_bsc: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub admin_nonce: i64,
    pub paused: bool,
    pub signer_set: String,
    pub guardian: String,
    /// DAA the minter must stand untouched before a recovery can be carried out.
    #[serde(default = "default_recovery_delay", deserialize_with = "crate::model::int::de")]
    pub recovery_delay: i64,
    #[serde(default, deserialize_with = "crate::model::int::de")]
    pub recovery_nonce: i64,
    #[serde(default)]
    pub recovery_pending: bool,
    #[serde(default = "zero_hex32")]
    pub recovery_signer_set: String,
    #[serde(default = "zero_hex32")]
    pub recovery_guardian: String,
}

/// 72 hours at 10 blocks per second (SPEC §6).
pub const MAINNET_RECOVERY_DELAY_DAA: i64 = 2_592_000;

fn default_recovery_delay() -> i64 {
    MAINNET_RECOVERY_DELAY_DAA
}

fn zero_hex32() -> String {
    "00".repeat(32)
}

impl MinterState {
    pub fn to_state(&self) -> Result<State, String> {
        Ok(state! {
            remaining: self.remaining,
            bucket: self.bucket,
            capacity: self.capacity,
            refill_per_daa: self.refill_per_daa,
            nonce_ethereum: self.nonce_ethereum,
            nonce_bsc: self.nonce_bsc,
            admin_nonce: self.admin_nonce,
            paused: self.paused,
            signer_set: bytes32(&self.signer_set, "signerSet")?.to_vec(),
            guardian: bytes32(&self.guardian, "guardian")?.to_vec(),
            extension_commitment: vec![0u8; 32],
            recovery_delay: self.recovery_delay,
            recovery_nonce: self.recovery_nonce,
            recovery_pending: self.recovery_pending,
            recovery_signer_set: bytes32(&self.recovery_signer_set, "recoverySignerSet")?.to_vec(),
            recovery_guardian: bytes32(&self.recovery_guardian, "recoveryGuardian")?.to_vec()
        })
    }

    /// Back to no recovery under way.
    pub fn clear_recovery(&mut self) {
        self.recovery_pending = false;
        self.recovery_signer_set = zero_hex32();
        self.recovery_guardian = zero_hex32();
    }

    /// The allowance once the minter UTXO is `age_daa` old, as the covenant computes it.
    pub fn refilled(&self, age_daa: i64) -> i64 {
        let mut filled = self.bucket as i128;
        if self.refill_per_daa > 0 && self.bucket < self.capacity {
            filled = (self.bucket as i128 + age_daa.max(0) as i128 * self.refill_per_daa as i128).min(self.capacity as i128);
        }
        filled.min(self.capacity as i128) as i64
    }
}

/// A covenant UTXO together with the state it holds.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Located<T> {
    pub utxo: Utxo,
    pub state: T,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MassReport {
    pub compute: u64,
    pub storage: u64,
    pub transient: u64,
    /// The mass the fee is paid on (max of the normalized dimensions).
    pub fee_mass: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltOutput {
    pub index: u32,
    /// "minter", "seed", "token", "change" or "output".
    pub kind: String,
    pub value: u64,
    pub script_public_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<TokenState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minter: Option<MinterState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pool: Option<crate::pool::PoolState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<crate::pool::PositionState>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Built {
    pub txid: String,
    /// The transaction in the node's wRPC JSON form, ready for submitTransaction.
    pub transaction: serde_json::Value,
    pub fee: u64,
    pub mass: MassReport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub covenant_id: Option<String>,
    pub outputs: Vec<BuiltOutput>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(json: &str) -> Result<TokenState, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    #[test]
    fn integers_as_numbers_or_decimal_strings() {
        let owner = "11".repeat(32);
        let a = token(&format!(r#"{{"amount":1000000000000000,"owner":"{owner}","ownerScheme":0}}"#)).unwrap();
        let b = token(&format!(r#"{{"amount":"1000000000000000","owner":"{owner}","ownerScheme":"0"}}"#)).unwrap();
        assert_eq!(a, b);
        assert_eq!(b.amount, 1_000_000_000_000_000);
        let max = token(&format!(r#"{{"amount":"9223372036854775807","owner":"{owner}","ownerScheme":0}}"#)).unwrap();
        assert_eq!(max.amount, i64::MAX);
    }

    #[test]
    fn refuses_floats_hex_and_out_of_range() {
        let owner = "11".repeat(32);
        for amount in ["1.5", "1e21", r#""0x10""#, r#""12a""#, r#""""#, r#""-""#, r#""9223372036854775808""#] {
            let err = token(&format!(r#"{{"amount":{amount},"owner":"{owner}","ownerScheme":0}}"#));
            assert!(err.is_err(), "accepted amount {amount}");
        }
        assert!(token(&format!(r#"{{"amount":1,"owner":"{owner}","ownerScheme":256}}"#)).is_err());
        assert!(token(&format!(r#"{{"amount":1,"owner":"{owner}","ownerScheme":-1}}"#)).is_err());
    }

    #[test]
    fn optional_integers() {
        #[derive(Deserialize)]
        struct T {
            #[serde(default, deserialize_with = "crate::model::int::opt")]
            v: Option<u64>,
        }
        let parse = |s: &str| serde_json::from_str::<T>(s).map(|t| t.v);
        assert_eq!(parse("{}").unwrap(), None);
        assert_eq!(parse(r#"{"v":null}"#).unwrap(), None);
        assert_eq!(parse(r#"{"v":"18446744073709551615"}"#).unwrap(), Some(u64::MAX));
        assert_eq!(parse(r#"{"v":7}"#).unwrap(), Some(7));
        assert!(parse(r#"{"v":-7}"#).is_err());
    }
}
