//! Protocol constants, digests, burn owners and the redemption payload (SPEC §6, §9).

pub const CHAIN_ETHEREUM: u8 = 0x01;
pub const CHAIN_BSC: u8 = 0x02;

pub const OWNER_P2PK_SCHNORR: u8 = 0x00;
pub const OWNER_P2PKH_SCHNORR: u8 = 0x01;
pub const OWNER_P2PKH_ECDSA: u8 = 0x02;
pub const OWNER_P2SH: u8 = 0x03;
pub const OWNER_COVENANT_ID: u8 = 0x04;

pub const BORROW_DISABLED: u8 = 0x00;

pub const ACTION_UNPAUSE: u8 = 0x01;
pub const ACTION_SET_LIMITS: u8 = 0x02;
pub const ACTION_SET_SIGNERS: u8 = 0x03;
pub const ACTION_SKIP_NONCE: u8 = 0x04;
pub const ACTION_SET_VALUE: u8 = 0x05;
pub const ACTION_PROPOSE_RECOVERY: u8 = 0x06;
pub const ACTION_VETO_RECOVERY: u8 = 0x07;

pub const SIGNERS: usize = 5;
pub const MINT_QUORUM: usize = 3;
pub const ADMIN_QUORUM: usize = 4;
pub const RECOVERY_QUORUM: usize = 3;
pub const VETO_QUORUM: usize = 1;
pub const MAX_MINTS: usize = 3;

/// The least KAS (sompi) every minted token output must carry: 1 KAS (bridge_mint.ag `MIN_MINTED_VALUE`).
/// The signers sign the kUSDT, not the KAS (whoever submits pays it), so the minter itself keeps a copy of a
/// signed mint from leaving a recipient too little KAS to move the kUSDT.
pub const MIN_MINTED_VALUE: u64 = 100_000_000;

/// The most inputs a minter or pool transaction may have (bridge_mint.ag `MAX_TX_INPUTS`).
pub const MAX_TX_INPUTS: usize = 8;

/// The DAA score a node gives an output of a transaction still in its mempool (rusty-kaspa's
/// `UNACCEPTED_DAA_SCORE`); the covenants read it as -1. A coin known only from the mempool is given
/// this score, so that the scripts a builder runs judge the transaction as a node will.
pub const UNACCEPTED_DAA_SCORE: u64 = u64::MAX;

/// 1 billion USDT in base units (10^-6).
pub const DEFAULT_CAP: i64 = 1_000_000_000_000_000;

pub fn chain_name(chain: u8) -> Option<&'static str> {
    match chain {
        CHAIN_ETHEREUM => Some("ethereum"),
        CHAIN_BSC => Some("bsc"),
        _ => None,
    }
}

/// `x as byte[8]` in the covenant: eight little-endian bytes (non-negative).
fn le8(x: i64) -> Result<[u8; 8], String> {
    if x < 0 {
        return Err(format!("{x} is negative; digests only carry non-negative numbers"));
    }
    Ok(x.to_le_bytes())
}

/// BLAKE3 of the five x-only signer keys, in order.
pub fn signer_set_of(keys: &[[u8; 32]]) -> Result<[u8; 32], String> {
    if keys.len() != SIGNERS {
        return Err(format!("a signer set has {SIGNERS} keys, not {}", keys.len()));
    }
    let mut packed = Vec::with_capacity(32 * SIGNERS);
    for key in keys {
        packed.extend_from_slice(key);
    }
    Ok(*blake3::hash(&packed).as_bytes())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MintRecipient {
    pub owner_scheme: u8,
    pub owner: [u8; 32],
    pub amount: i64,
}

/// The digest 3 signers sign to mint (SPEC §6).
pub fn mint_digest(
    covenant_id: &[u8; 32],
    chain: u8,
    first_nonce: i64,
    age_daa: i64,
    recipients: &[MintRecipient],
) -> Result<[u8; 32], String> {
    let mut message = b"kUSDT/mint/v2".to_vec();
    message.extend_from_slice(covenant_id);
    message.push(chain);
    message.extend_from_slice(&le8(first_nonce)?);
    message.extend_from_slice(&le8(age_daa)?);
    for r in recipients {
        message.push(r.owner_scheme);
        message.extend_from_slice(&r.owner);
        message.extend_from_slice(&le8(r.amount)?);
    }
    Ok(*blake3::hash(&message).as_bytes())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GovernAction {
    Unpause,
    SetLimits { capacity: i64, refill_per_daa: i64 },
    SetSigners { signer_set: [u8; 32], guardian: [u8; 32] },
    SkipNonce { chain: u8, nonce: i64 },
    SetValue { value: i64 },
    ProposeRecovery { signer_set: [u8; 32], guardian: [u8; 32] },
    VetoRecovery,
}

impl GovernAction {
    pub fn code(&self) -> u8 {
        match self {
            Self::Unpause => ACTION_UNPAUSE,
            Self::SetLimits { .. } => ACTION_SET_LIMITS,
            Self::SetSigners { .. } => ACTION_SET_SIGNERS,
            Self::SkipNonce { .. } => ACTION_SKIP_NONCE,
            Self::SetValue { .. } => ACTION_SET_VALUE,
            Self::ProposeRecovery { .. } => ACTION_PROPOSE_RECOVERY,
            Self::VetoRecovery => ACTION_VETO_RECOVERY,
        }
    }

    pub fn quorum(&self) -> usize {
        match self {
            Self::ProposeRecovery { .. } => RECOVERY_QUORUM,
            Self::VetoRecovery => VETO_QUORUM,
            _ => ADMIN_QUORUM,
        }
    }

    /// A recovery proposal or veto: signed at the recovery nonce, and leaves the admin nonce alone.
    pub fn is_recovery(&self) -> bool {
        matches!(self, Self::ProposeRecovery { .. } | Self::VetoRecovery)
    }

    pub fn params(&self) -> Result<Vec<u8>, String> {
        Ok(match self {
            Self::Unpause => Vec::new(),
            Self::SetLimits { capacity, refill_per_daa } => {
                let mut p = le8(*capacity)?.to_vec();
                p.extend_from_slice(&le8(*refill_per_daa)?);
                p
            }
            Self::SetSigners { signer_set, guardian } => {
                let mut p = signer_set.to_vec();
                p.extend_from_slice(guardian);
                p
            }
            Self::SkipNonce { chain, nonce } => {
                let mut p = vec![*chain];
                p.extend_from_slice(&le8(*nonce)?);
                p
            }
            Self::SetValue { value } => le8(*value)?.to_vec(),
            Self::ProposeRecovery { signer_set, guardian } => {
                let mut p = signer_set.to_vec();
                p.extend_from_slice(guardian);
                p
            }
            Self::VetoRecovery => Vec::new(),
        })
    }
}

/// The outpoint of a coin: the transaction that made it and the output's index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Outpoint {
    pub transaction_id: [u8; 32],
    pub index: u32,
}

/// The digest four signers sign to lift a pause (SPEC §6). It names the paused minter coin itself, so it cannot be
/// signed before the pause exists and serves that one coin only, and the age of that coin the spend claims:
/// `BLAKE3("kUSDT/unpause/v2" ‖ covenant_id[32] ‖ admin_nonce[8] ‖ age_daa[8] ‖ outpoint_txid[32] ‖ outpoint_index[8])`.
pub fn unpause_digest(covenant_id: &[u8; 32], admin_nonce: i64, age_daa: i64, minter: &Outpoint) -> Result<[u8; 32], String> {
    let mut message = b"kUSDT/unpause/v2".to_vec();
    message.extend_from_slice(covenant_id);
    message.extend_from_slice(&le8(admin_nonce)?);
    message.extend_from_slice(&le8(age_daa)?);
    message.extend_from_slice(&minter.transaction_id);
    message.extend_from_slice(&le8(minter.index as i64)?);
    Ok(*blake3::hash(&message).as_bytes())
}

/// The digest signers sign for a governance action (SPEC §6). `admin_nonce` is the minter's
/// recovery nonce for a recovery proposal or veto (`GovernAction::is_recovery`). An unpause signs
/// `unpause_digest` instead: it needs `minter`, the outpoint of the paused minter coin it spends; every other
/// action ignores it.
///
/// `age_daa` is the age of the minter UTXO the spend claims, which settles the mint allowance: it is signed, as a
/// mint's is, so the transaction must claim exactly this age (0 is always valid and credits no refill):
/// `BLAKE3("kUSDT/govern/v2" ‖ covenant_id[32] ‖ nonce[8] ‖ age_daa[8] ‖ action[1] ‖ params)`.
pub fn govern_digest(covenant_id: &[u8; 32], admin_nonce: i64, age_daa: i64, action: &GovernAction, minter: Option<&Outpoint>) -> Result<[u8; 32], String> {
    if matches!(action, GovernAction::Unpause) {
        let minter = minter.ok_or("an unpause signs the outpoint of the paused minter coin: give it")?;
        return unpause_digest(covenant_id, admin_nonce, age_daa, minter);
    }
    let mut message = b"kUSDT/govern/v2".to_vec();
    message.extend_from_slice(covenant_id);
    message.extend_from_slice(&le8(admin_nonce)?);
    message.extend_from_slice(&le8(age_daa)?);
    message.push(action.code());
    message.extend_from_slice(&action.params()?);
    Ok(*blake3::hash(&message).as_bytes())
}

/// `R(chain, address)`: a script that starts with OP_RETURN, so it can never
/// be satisfied, and that names where a redemption is paid (SPEC §9).
pub fn burn_script(chain: u8, address: &[u8; 20]) -> Vec<u8> {
    let tag = b"kUSDT/redeem/v1";
    let mut script = Vec::with_capacity(1 + 1 + tag.len() + 2 + 1 + 20);
    script.push(0x6a); // OP_RETURN
    script.push(tag.len() as u8);
    script.extend_from_slice(tag);
    script.push(0x01);
    script.push(chain);
    script.push(0x14);
    script.extend_from_slice(address);
    script
}

/// The p2sh owner (BLAKE2b-256 of `R`) that redeems to `address` on `chain`.
pub fn burn_owner(chain: u8, address: &[u8; 20]) -> [u8; 32] {
    let hash = blake2b_simd::Params::new().hash_length(32).hash(&burn_script(chain, address));
    let mut owner = [0u8; 32];
    owner.copy_from_slice(hash.as_bytes());
    owner
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RedeemEntry {
    pub output_index: u8,
    pub chain: u8,
    pub address: [u8; 20],
}

const PAYLOAD_MAGIC: &[u8; 5] = b"KUSDT";
const PAYLOAD_REDEEM: u8 = 0x01;

/// `"KUSDT" ‖ 01 ‖ count ‖ (output_index ‖ chain ‖ address[20])*`
pub fn redeem_payload(entries: &[RedeemEntry]) -> Result<Vec<u8>, String> {
    if entries.is_empty() || entries.len() > 255 {
        return Err("a redemption payload names 1 to 255 outputs".into());
    }
    let mut payload = PAYLOAD_MAGIC.to_vec();
    payload.push(PAYLOAD_REDEEM);
    payload.push(entries.len() as u8);
    for e in entries {
        payload.push(e.output_index);
        payload.push(e.chain);
        payload.extend_from_slice(&e.address);
    }
    Ok(payload)
}

/// Parses a redemption payload. Anything else (no payload, another format)
/// is `None`, never an error: payloads are optional hints (SPEC §9).
pub fn parse_redeem_payload(payload: &[u8]) -> Option<Vec<RedeemEntry>> {
    let rest = payload.strip_prefix(PAYLOAD_MAGIC.as_slice())?;
    let (&kind, rest) = rest.split_first()?;
    let (&count, mut rest) = rest.split_first()?;
    if kind != PAYLOAD_REDEEM || count == 0 || rest.len() != count as usize * 22 {
        return None;
    }
    let mut entries = Vec::with_capacity(count as usize);
    while let Some((head, tail)) = rest.split_first_chunk::<22>() {
        let mut address = [0u8; 20];
        address.copy_from_slice(&head[2..]);
        entries.push(RedeemEntry { output_index: head[0], chain: head[1], address });
        rest = tail;
    }
    Some(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redeem_payload_round_trips() {
        let entries = vec![
            RedeemEntry { output_index: 0, chain: CHAIN_ETHEREUM, address: [0x11; 20] },
            RedeemEntry { output_index: 2, chain: CHAIN_BSC, address: [0x22; 20] },
        ];
        let payload = redeem_payload(&entries).unwrap();
        assert_eq!(payload.len(), 7 + 2 * 22);
        assert_eq!(parse_redeem_payload(&payload), Some(entries));
        assert_eq!(parse_redeem_payload(&payload[..payload.len() - 1]), None);
        assert_eq!(parse_redeem_payload(b"hello"), None);
    }

    #[test]
    fn burn_owners_differ_by_chain_and_address() {
        let a = burn_owner(CHAIN_ETHEREUM, &[0x11; 20]);
        assert_ne!(a, burn_owner(CHAIN_BSC, &[0x11; 20]));
        assert_ne!(a, burn_owner(CHAIN_ETHEREUM, &[0x12; 20]));
        assert_eq!(burn_script(CHAIN_ETHEREUM, &[0x11; 20])[0], 0x6a);
        assert_eq!(burn_script(CHAIN_ETHEREUM, &[0x11; 20]).len(), 40);
    }

    #[test]
    fn digests_reject_negative_numbers() {
        assert!(mint_digest(&[0; 32], CHAIN_ETHEREUM, -1, 0, &[]).is_err());
    }
}
