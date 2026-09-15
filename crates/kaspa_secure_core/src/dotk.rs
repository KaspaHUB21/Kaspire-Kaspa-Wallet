//! Read-only dot.k mainnet v4 deed derivation. No keys, signing or remote code.
//! Registry/template pinned from https://dotk.name/integrators (2026-09-15).
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_txscript::{extract_script_pub_key_address, pay_to_script_hash_script};
use serde::{Deserialize, Serialize};

pub const REGISTRY: &str = "ee2128c03dfac7f6d74734bb3c879bd999434c47a55945b8a6daae2a1e4a21de";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub name: String,
    pub owner_type: u8,
    pub owner: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DerivedDeed {
    pub name: String,
    pub address: Option<String>,
    pub deed_address: String,
    pub script_public_key: String,
    pub registry_covenant_id: &'static str,
    pub bond: u64,
}

pub fn derive(request: &Request) -> Result<DerivedDeed> {
    let invalid = || CoreError::InvalidRequest("invalid dot.k name or owner".into());
    let name = request.name.as_bytes();
    if name.is_empty()
        || name.len() > 32
        || name[0] == b'-'
        || name[name.len() - 1] == b'-'
        || !name
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
    {
        return Err(invalid());
    }
    let owner = hex::decode(&request.owner).map_err(|_| invalid())?;
    if owner.len() != 32 || owner.iter().all(|b| *b == 0) {
        return Err(invalid());
    }
    let address = match request.owner_type {
        0 => {
            secp256k1::XOnlyPublicKey::from_slice(&owner).map_err(|_| invalid())?;
            Some(Address::new(Prefix::Mainnet, Version::PubKey, &owner))
        }
        3 => Some(Address::new(Prefix::Mainnet, Version::ScriptHash, &owner)),
        4 => {
            if request.owner.eq_ignore_ascii_case(REGISTRY) {
                return Err(invalid());
            }
            None // A lineage has no payment address. Never invent one.
        }
        0x85 | 0x86 => {
            let mut key = vec![0x02 | (request.owner_type & 1)];
            key.extend_from_slice(&owner);
            secp256k1::PublicKey::from_slice(&key).map_err(|_| invalid())?;
            Some(Address::new(Prefix::Mainnet, Version::PubKeyECDSA, &key))
        }
        _ => return Err(invalid()),
    };
    let deployment: serde_json::Value = serde_json::from_str(include_str!("dotk_mainnet.json"))
        .map_err(|_| CoreError::Serialization)?;
    let mut redeem = hex::decode(
        deployment["bytecode"]
            .as_str()
            .ok_or(CoreError::Serialization)?,
    )
    .map_err(|_| CoreError::Serialization)?;
    let mut state = vec![1, 2, 32];
    state.extend_from_slice(blake3::hash(name).as_bytes());
    state.extend_from_slice(&[1, request.owner_type, 32]);
    state.extend_from_slice(&owner);
    state.push(32);
    state.extend_from_slice(name);
    state.resize(103, 0);
    redeem[1..104].copy_from_slice(&state);
    let spk = pay_to_script_hash_script(&redeem);
    let deed = extract_script_pub_key_address(&spk, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?;
    Ok(DerivedDeed {
        name: request.name.clone(),
        address: address.map(|a| a.to_string()),
        deed_address: deed.to_string(),
        script_public_key: hex::encode(spk.script()),
        registry_covenant_id: REGISTRY,
        bond: 100_000_000,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Request {
        Request {
            name: "21millioncoven".into(),
            owner_type: 0,
            owner: "079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449".into(),
        }
    }
    #[test]
    fn live_mainnet_deed_vector() {
        let result = derive(&request()).unwrap();
        assert_eq!(
            result.address.unwrap(),
            "kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq"
        );
        assert_eq!(
            result.deed_address,
            "kaspa:pz7hc3eyu6z6f6xgmp5e843a7xpwqag6rywp3s8r96a0yvg0kgy2xcazlrru8"
        );
    }
    #[test]
    fn rejects_bad_names_and_owners() {
        for name in [
            "",
            "test.k",
            "TEST",
            "-test",
            "test-",
            "téšt",
            "a.b",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            let mut r = request();
            r.name = name.into();
            assert!(derive(&r).is_err());
        }
        for scheme in [1, 2, 5, 6, 255] {
            let mut r = request();
            r.owner_type = scheme;
            assert!(derive(&r).is_err());
        }
        let mut r = request();
        r.owner = "00".repeat(32);
        assert!(derive(&r).is_err());
    }
    #[test]
    fn owner_and_name_are_bound_and_covenants_have_no_address() {
        let first = derive(&request()).unwrap();
        let mut r = request();
        r.name = "other".into();
        assert_ne!(first.deed_address, derive(&r).unwrap().deed_address);
        r.owner_type = 4;
        assert!(derive(&r).unwrap().address.is_none());
        r.owner_type = 3;
        assert!(derive(&r).unwrap().address.unwrap().starts_with("kaspa:p"));
        r.owner_type = 0x85;
        let odd = derive(&r).unwrap().address.unwrap();
        r.owner_type = 0x86;
        assert_ne!(odd, derive(&r).unwrap().address.unwrap());
    }
}
