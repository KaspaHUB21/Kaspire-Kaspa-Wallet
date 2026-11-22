//! Transaction builders for the kUSDT family: KCC-23 preparation, genesis,
//! mint, KCC-20 transfers (sends and redemptions), pause and governance.
//!
//! Each builder assembles the transaction with argent-runtime, which fills
//! the covenants' hidden witnesses, signs, runs every input through the script
//! engine and commits compute budgets. The fee is then the network fee rate
//! times the transaction's normalized mass (Kaspa's own mass calculator), paid
//! out of the funding inputs; the rest returns as change.

use std::sync::OnceLock;

use argent_artifact::Artifact;
use argent_runtime::{ArtifactValue, EntryCall, InputSigScript, TxBuilder, TxContext, args};
use kaspa_addresses::{Address, Version};
use kaspa_consensus_core::{
    Hash,
    config::params::{DEVNET_PARAMS, MAINNET_PARAMS, Params, SIMNET_PARAMS, TESTNET_PARAMS},
    hashing::{
        sighash::{SigHashReusedValuesUnsync, calc_schnorr_signature_hash},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{ContextualMasses, Mass, MassCalculator},
    tx::{CovenantBinding, MutableTransaction, PopulatedTransaction, ScriptPublicKey, Transaction, UtxoEntry},
};
use kaspa_txscript::pay_to_address_script;
use secp256k1::{Keypair, Message, PublicKey, Secp256k1, SecretKey, XOnlyPublicKey};
use serde::{Deserialize, Serialize};

use crate::{
    hex,
    model::{
        Built, BuiltOutput, Funding, Located, MassReport, MinterState, TokenState, Utxo, bytes32, spk_to_hex,
    },
    protocol::{self, GovernAction, MintRecipient, RedeemEntry},
};

/// The compiled kUSDT app, as checked in (see `examples/build_artifacts.rs`).
pub fn artifact() -> &'static Artifact {
    static ARTIFACT: OnceLock<Artifact> = OnceLock::new();
    ARTIFACT.get_or_init(|| {
        serde_json::from_str(include_str!("../artifacts/kusdt.json")).expect("the checked-in artifact parses")
    })
}

pub(crate) fn builder() -> Result<TxBuilder<'static>, String> {
    TxBuilder::new(artifact()).map_err(|e| e.to_string())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Network {
    #[serde(rename = "mainnet")]
    Mainnet,
    #[serde(rename = "testnet-10")]
    Testnet10,
    #[serde(rename = "simnet")]
    Simnet,
    #[serde(rename = "devnet")]
    Devnet,
}

impl Network {
    pub fn params(self) -> &'static Params {
        match self {
            Self::Mainnet => &MAINNET_PARAMS,
            Self::Testnet10 => &TESTNET_PARAMS,
            Self::Simnet => &SIMNET_PARAMS,
            Self::Devnet => &DEVNET_PARAMS,
        }
    }
}

/// The relay minimum, in sompi per gram of normalized mass.
/// The highest allowance ceiling and refill rate the minter takes (bridge_mint.ag MAX_LIMIT): the lifetime cap in base units.
pub const MAX_LIMIT: i64 = 1_000_000_000_000_000;
pub const MIN_FEERATE: u64 = 100;
/// The largest normalized mass these builders produce. Before Toccata, mempools
/// relayed at most 100 000 per transaction; that cap is lifted for good 30 minutes
/// before Toccata activates (kaspad mining/src/mempool/check_transaction_standard.rs),
/// and covenant transactions only exist after it. A transaction must then only fit
/// in a block (500 000 compute and storage, 1 000 000 transient); 300 000 keeps any
/// one well short of filling one.
pub const MAX_STANDARD_MASS: u64 = 300_000;
/// Smaller change is left to the fee: a tiny output costs more storage mass
/// than it is worth.
pub const MIN_CHANGE: u64 = 20_000_000;

/// What every builder takes besides its own fields.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Common {
    pub network: Network,
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::opt")]
    pub feerate: Option<u64>,
    /// Plain P2PK coins that pay for values and the fee.
    #[serde(default)]
    pub funding: Vec<Funding>,
    /// Where change goes.
    pub change_address: String,
}

pub(crate) struct FundingInput {
    pub outpoint: kaspa_consensus_core::tx::TransactionOutpoint,
    pub entry: UtxoEntry,
    pub key: Keypair,
}

pub(crate) fn keypair(secret_hex: &str) -> Result<Keypair, String> {
    let secret = SecretKey::from_slice(&bytes32(secret_hex, "secretKey")?).map_err(|e| format!("secretKey: {e}"))?;
    Ok(Keypair::from_secret_key(&Secp256k1::new(), &secret))
}

pub(crate) fn funding_inputs(funding: &[Funding]) -> Result<Vec<FundingInput>, String> {
    funding
        .iter()
        .map(|f| {
            let entry = f.utxo.entry()?;
            if entry.covenant_id.is_some() {
                return Err("funding coins must be plain coins, not covenant states".into());
            }
            if !is_schnorr_p2pk(&entry.script_public_key) {
                return Err(format!(
                    "funding coin {}:{} is not a plain Schnorr P2PK coin, the only plain coin the minter and the pool take",
                    f.utxo.transaction_id, f.utxo.index
                ));
            }
            Ok(FundingInput { outpoint: f.utxo.outpoint()?, entry, key: keypair(&f.secret_key)? })
        })
        .collect()
}

/// A plain Schnorr P2PK script (version 0, a 32-byte key, OP_CHECKSIG).
pub(crate) fn is_schnorr_p2pk(spk: &ScriptPublicKey) -> bool {
    let script = spk.script();
    spk.version() == 0 && script.len() == 34 && script[0] == 0x20 && script[33] == 0xac
}

/// What the minter and the pool demand of a transaction's other inputs (bridge_mint.ag
/// `require_settled_inputs`), said here in words before the scripts say it as a failure: at most
/// `MAX_TX_INPUTS` inputs in all, and a coin still in the mempool only if the transaction that made
/// the state coin made it too.
pub(crate) fn check_settled_inputs(state: &Utxo, others: &[&Utxo]) -> Result<(), String> {
    if 1 + others.len() > protocol::MAX_TX_INPUTS {
        return Err(format!(
            "a minter or pool transaction takes at most {} inputs and this one needs {}: merge the coins first",
            protocol::MAX_TX_INPUTS,
            1 + others.len()
        ));
    }
    let parent = state.outpoint()?.transaction_id;
    for other in others {
        if other.block_daa_score == protocol::UNACCEPTED_DAA_SCORE && other.outpoint()?.transaction_id != parent {
            return Err(format!(
                "coin {}:{} is still in the mempool and was not made with the state coin: use it once it is in a block",
                other.transaction_id, other.index
            ));
        }
    }
    Ok(())
}

/// A positive age is claimed only on a minter or pool coin already in a block: a node checks no
/// relative lock on a coin still in its mempool, so the covenants refuse the claim there. As the
/// script does, this reads a coin as unconfirmed only when it carries the node's mark for it
/// (`UNACCEPTED_DAA_SCORE`); a caller that could not place the coin claims 0.
pub(crate) fn check_claim(state: &Utxo, age_daa: u64) -> Result<(), String> {
    if age_daa > 0 && state.block_daa_score > i64::MAX as u64 {
        return Err(format!(
            "a claimed age of {age_daa} DAA needs the state coin {}:{} in a block, and it is still in the mempool: claim 0, or wait",
            state.transaction_id, state.index
        ));
    }
    Ok(())
}

/// The key of a p2pk-schnorr token owner, checked against the state.
pub(crate) fn check_owner_key(state: &TokenState, secret_hex: &str) -> Result<Keypair, String> {
    if state.owner_scheme != protocol::OWNER_P2PK_SCHNORR {
        return Err("only p2pk-schnorr token owners are signed by these builders".into());
    }
    let key = keypair(secret_hex)?;
    if key.x_only_public_key().0.serialize() != bytes32(&state.owner, "owner")? {
        return Err("a secret key does not own its token state".into());
    }
    Ok(key)
}

/// A BIP-340 Schnorr signature with SIGHASH_ALL over input `index`.
pub(crate) fn schnorr_tx_signature(tx: &MutableTransaction<Transaction>, index: usize, key: &Keypair) -> Vec<u8> {
    let digest = calc_schnorr_signature_hash(&tx.as_verifiable(), index, SIG_HASH_ALL, &SigHashReusedValuesUnsync::new());
    let signature = Secp256k1::new().sign_schnorr_no_aux_rand(&Message::from_digest(digest.as_bytes()), key);
    let mut out = signature.as_ref().to_vec();
    out.push(SIG_HASH_ALL.to_u8());
    out
}

/// Signature script of a P2PK input: one push of the 65-byte signature.
pub(crate) fn p2pk_sig_script<'a>(key: Keypair) -> InputSigScript<'a> {
    InputSigScript::with_transaction(move |tx, index| {
        let signature = schnorr_tx_signature(tx, index, &key);
        let mut script = vec![0x41];
        script.extend_from_slice(&signature);
        script
    })
}

/// The script that pays `address`, for an address something can spend from.
pub fn address_script(address: &str) -> Result<ScriptPublicKey, String> {
    // rusty-kaspa's parser asserts that the payload has its version's length and reads a version byte that may not be
    // there: a panic, which stops the CLI and traps the WebAssembly module. So both are read from the characters first,
    // as its decoder reads them (5 bits a character; the last 8 characters are the checksum).
    const CHARSET: &[u8] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    let data = address.split_once(':').map_or("", |(_, data)| data);
    let values = data.bytes().map(|c| CHARSET.iter().position(|&x| x == c)).collect::<Option<Vec<_>>>();
    if let Some(values) = values.filter(|v| v.len() >= 8) {
        let bytes = (values.len() - 8) * 5 / 8;
        if bytes == 0 {
            return Err(format!("address {address}: it holds no version byte"));
        }
        let version = values[0] << 3 | values[1] >> 2;
        let length = match version {
            0 | 8 => Some(32),
            1 => Some(33),
            _ => None,
        };
        if let Some(length) = length.filter(|&length| length != bytes - 1) {
            return Err(format!("address {address}: its version-{version} payload has {} bytes, not {length}", bytes - 1));
        }
    }
    let parsed = Address::try_from(address).map_err(|e| format!("address {address}: {e}"))?;
    // A key that is no point on the curve passes the checksum, and nothing can ever sign for it: what is paid there is lost.
    let key_on_curve = match parsed.version {
        Version::PubKey => XOnlyPublicKey::from_slice(&parsed.payload).is_ok(),
        Version::PubKeyECDSA => PublicKey::from_slice(&parsed.payload).is_ok(),
        Version::ScriptHash => true,
    };
    if !key_on_curve {
        return Err(format!("address {address}: its key is no point on secp256k1, so nothing could ever spend from it"));
    }
    Ok(pay_to_address_script(&parsed))
}

fn mass_of(tx: &Transaction, entries: &[UtxoEntry], params: &Params) -> MassReport {
    let calculator = MassCalculator::new_with_consensus_params(params);
    let non_contextual = calculator.calc_non_contextual_masses(tx);
    let populated = PopulatedTransaction::new(tx, entries.to_vec());
    let storage = calculator.calc_contextual_masses(&populated).map(|m| m.storage_mass).unwrap_or(u64::MAX);
    let mass = Mass::new(non_contextual, ContextualMasses::new(storage));
    MassReport {
        compute: non_contextual.compute_mass,
        storage,
        transient: non_contextual.transient_mass,
        fee_mass: mass.normalized_max(&params.block_mass_limits().after().cofactors()),
    }
}

/// The transaction in the node's wRPC JSON form (field for field what
/// submitTransaction deserializes). `mass` and `storageMass` are 0: the node
/// computes both itself and refuses a submission that carries a storage mass.
pub fn rpc_json(tx: &Transaction) -> serde_json::Value {
    use serde_json::json;
    let inputs: Vec<_> = tx
        .inputs
        .iter()
        .map(|i| {
            json!({
                "previousOutpoint": {
                    "transactionId": i.previous_outpoint.transaction_id.to_string(),
                    "index": i.previous_outpoint.index,
                },
                "signatureScript": hex::encode(&i.signature_script),
                "sequence": i.sequence,
                "sigOpCount": i.compute_commit.sig_op_count().unwrap_or(0),
                "computeBudget": i.compute_commit.compute_budget().unwrap_or(0),
                "verboseData": null,
            })
        })
        .collect();
    let outputs: Vec<_> = tx
        .outputs
        .iter()
        .map(|o| {
            json!({
                "value": o.value,
                "scriptPublicKey": spk_to_hex(&o.script_public_key),
                "verboseData": null,
                "covenant": o.covenant.map(|c| json!({
                    "authorizingInput": c.authorizing_input,
                    "covenantId": c.covenant_id.to_string(),
                })),
            })
        })
        .collect();
    json!({
        "version": tx.version,
        "inputs": inputs,
        "outputs": outputs,
        "lockTime": tx.lock_time,
        "subnetworkId": hex::encode(tx.subnetwork_id.as_ref()),
        "gas": tx.gas,
        "payload": hex::encode(&tx.payload),
        "mass": 0,
        "storageMass": 0,
        "verboseData": null,
    })
}

/// One assembled candidate: the context for a given change output.
pub(crate) type MakeContext<'f> = dyn Fn(Option<(ScriptPublicKey, u64)>) -> Result<TxContext<'f>, String> + 'f;

/// Relay policy: at most 15 signature operations per P2SH input, counted
/// statically over the whole redeem script (kaspad's p2sh sig-op scanner).
pub const MAX_STANDARD_P2SH_SIG_OPS: u64 = 15;

pub fn check_standard_sig_ops(tx: &Transaction, entries: &[UtxoEntry]) -> Result<(), String> {
    for (i, (input, entry)) in tx.inputs.iter().zip(entries).enumerate() {
        let sig_ops = kaspa_txscript::post_toccata_p2sh_sig_scanner(&input.signature_script, &entry.script_public_key);
        if sig_ops > MAX_STANDARD_P2SH_SIG_OPS {
            return Err(format!("input {i} has {sig_ops} signature operations; nodes relay at most {MAX_STANDARD_P2SH_SIG_OPS}"));
        }
    }
    Ok(())
}

/// Builds, prices and re-builds until the fee covers the mass.
pub(crate) fn finish(builder: &TxBuilder<'_>, common: &Common, entries: Vec<UtxoEntry>, outputs_total: u64, make: &MakeContext<'_>) -> Result<(Transaction, u64, MassReport), String> {
    let params = common.network.params();
    let feerate = common.feerate.unwrap_or(MIN_FEERATE).max(MIN_FEERATE);
    let change_script = address_script(&common.change_address)?;
    let inputs_total: u64 = entries.iter().map(|e| e.amount).sum();
    let available = inputs_total
        .checked_sub(outputs_total)
        .ok_or_else(|| format!("inputs hold {inputs_total} sompi, outputs need {outputs_total}: add funding"))?;
    let mut fee = 0u64;
    for _ in 0..8 {
        let left = available.checked_sub(fee).ok_or_else(|| format!("the fee of {fee} sompi exceeds the {available} sompi left: add funding"))?;
        let change = (left >= MIN_CHANGE).then(|| (change_script.clone(), left));
        let paid = available - change.as_ref().map_or(0, |c| c.1);
        let tx = builder.build(&make(change)?).map_err(|e| e.to_string())?;
        check_standard_sig_ops(&tx, &entries)?;
        let mass = mass_of(&tx, &entries, params);
        if mass.fee_mass > MAX_STANDARD_MASS {
            return Err(format!(
                "the transaction's mass {} (compute {}, storage {}, transient {}) is above the standard limit {MAX_STANDARD_MASS}; \
                 covenant outputs need more KAS to lower the storage mass",
                mass.fee_mass, mass.compute, mass.storage, mass.transient
            ));
        }
        let needed = mass.fee_mass * feerate;
        if paid >= needed {
            return Ok((tx, paid, mass));
        }
        fee = needed;
    }
    Err("the fee did not settle".into())
}

pub(crate) fn describe(tx: &Transaction, fee: u64, mass: MassReport, covenant_id: Option<Hash>, kinds: &[(&str, Option<TokenState>, Option<MinterState>)]) -> Built {
    let outputs = tx
        .outputs
        .iter()
        .enumerate()
        .map(|(index, o)| {
            let (kind, token, minter) = kinds.get(index).cloned().unwrap_or(("change", None, None));
            BuiltOutput {
                index: index as u32,
                kind: kind.to_string(),
                value: o.value,
                script_public_key: spk_to_hex(&o.script_public_key),
                token,
                minter,
                pool: None,
                position: None,
            }
        })
        .collect();
    Built {
        txid: tx.id().to_string(),
        transaction: rpc_json(tx),
        fee,
        mass,
        covenant_id: covenant_id.map(|c| c.to_string()),
        outputs,
    }
}

fn bytes_array(items: impl IntoIterator<Item = Vec<u8>>) -> ArtifactValue {
    ArtifactValue::Array(items.into_iter().map(ArtifactValue::Bytes).collect())
}

/// Signer keys, indices and signatures as entry arguments, checked for shape.
fn quorum_args(keys: &[String], indices: &[u8], signatures: &[String], quorum: usize) -> Result<(ArtifactValue, Vec<u8>, ArtifactValue), String> {
    if keys.len() != protocol::SIGNERS {
        return Err(format!("{} signer keys given, the set has {}", keys.len(), protocol::SIGNERS));
    }
    if indices.len() != quorum || signatures.len() != quorum {
        return Err(format!("this action needs exactly {quorum} signatures"));
    }
    let keys = keys.iter().map(|k| bytes32(k, "signerKeys").map(|b| b.to_vec())).collect::<Result<Vec<_>, _>>()?;
    let signatures = signatures
        .iter()
        .map(|s| {
            let bytes = hex::decode(s)?;
            if bytes.len() != 64 {
                return Err(format!("a signature has 64 bytes, not {}", bytes.len()));
            }
            Ok(bytes)
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok((bytes_array(keys), indices.to_vec(), bytes_array(signatures)))
}

// ---------------------------------------------------------------------------
// KCC-23 preparation

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareRequest {
    #[serde(flatten)]
    pub common: Common,
    /// The token metadata (KCC-23 §3.1): one JSON object.
    pub metadata: serde_json::Value,
    /// The output the genesis transaction will spend first.
    pub genesis_address: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub genesis_value: u64,
}

pub fn prepare(req: &PrepareRequest) -> Result<Built, String> {
    if !req.metadata.is_object() {
        return Err("KCC-23 metadata is one JSON object".into());
    }
    let mut payload = vec![0x00];
    payload.extend_from_slice(serde_json::to_string(&req.metadata).map_err(|e| e.to_string())?.as_bytes());
    let funding = funding_inputs(&req.common.funding)?;
    let entries: Vec<_> = funding.iter().map(|f| f.entry.clone()).collect();
    let genesis_script = address_script(&req.genesis_address)?;
    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new().payload(payload.clone());
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.output(genesis_script.clone(), None, req.genesis_value);
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder()?, &req.common, entries, req.genesis_value, &make)?;
    Ok(describe(&tx, fee, mass, None, &[("output", None, None)]))
}

// ---------------------------------------------------------------------------
// Split: plain coins into several of one value, for a payer that spends one coin per transaction (the pool keeper)

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitRequest {
    #[serde(flatten)]
    pub common: Common,
    /// How many coins of `value` to make, each to the change address (1 to 16). What is left is change, or, when
    /// under MIN_CHANGE, goes to the last coin rather than to the fee.
    pub count: u32,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub value: u64,
}

/// The highest feerate a split takes (sompi a gram): ten times the floor, as the pool keeper's ceiling.
pub const SPLIT_MAX_FEERATE: u64 = 10 * MIN_FEERATE;

pub fn split(req: &SplitRequest) -> Result<Built, String> {
    if !(1..=16).contains(&req.count) {
        return Err("count must be 1..=16".into());
    }
    if req.value < MIN_CHANGE {
        return Err(format!("each coin must hold at least {MIN_CHANGE} sompi"));
    }
    if req.common.feerate.is_some_and(|f| f > SPLIT_MAX_FEERATE) {
        return Err(format!("a split's feerate is at most {SPLIT_MAX_FEERATE} sompi a gram"));
    }
    let total = req.value.checked_mul(req.count as u64).ok_or("the coins' total overflows")?;
    let funding = funding_inputs(&req.common.funding)?;
    if funding.is_empty() {
        return Err("a split needs funding".into());
    }
    let entries: Vec<_> = funding.iter().map(|f| f.entry.clone()).collect();
    let to = address_script(&req.common.change_address)?;
    let (funding, to) = (&funding, &to);
    let make_with = |extra: u64| {
        move |change: Option<(ScriptPublicKey, u64)>| {
            let mut context = TxContext::new();
            for f in funding {
                context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
            }
            for n in 0..req.count {
                let last = n + 1 == req.count;
                context = context.output(to.clone(), None, req.value + if last { extra } else { 0 });
            }
            if let Some((script, value)) = change {
                context = context.output(script, None, value);
            }
            Ok(context)
        }
    };
    let builder = builder()?;
    let (mut tx, mut fee, mut mass) = finish(&builder, &req.common, entries.clone(), total, &make_with(0))?;
    // A remainder too small for change would all be fee: it goes to the last coin instead, the fee then paid exactly.
    let feerate = req.common.feerate.unwrap_or(MIN_FEERATE).max(MIN_FEERATE);
    if tx.outputs.len() == req.count as usize && fee > mass.fee_mass * feerate {
        let mut extra = fee - mass.fee_mass * feerate;
        for _ in 0..4 {
            let (t, f, m) = finish(&builder, &req.common, entries.clone(), total + extra, &make_with(extra))?;
            (tx, fee, mass) = (t, f, m);
            // A larger last coin only lowers the storage mass, so the fee due never rises: this settles from above.
            let due = mass.fee_mass * feerate;
            if fee <= due {
                break;
            }
            extra += fee - due;
        }
    }
    let kinds: Vec<(&str, Option<TokenState>, Option<MinterState>)> = (0..req.count).map(|_| ("coin", None, None)).collect();
    Ok(describe(&tx, fee, mass, None, &kinds))
}

// ---------------------------------------------------------------------------
// Genesis

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenesisRequest {
    #[serde(flatten)]
    pub common: Common,
    pub minter: MinterState,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub minter_value: u64,
    /// x-only key that may rebalance the TokenSeed's KAS deposit.
    pub seed_owner: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub seed_value: u64,
}

pub fn genesis(req: &GenesisRequest) -> Result<Built, String> {
    let funding = funding_inputs(&req.common.funding)?;
    if funding.is_empty() {
        return Err("genesis spends at least one funding coin (the first is the authorizing input)".into());
    }
    let entries: Vec<_> = funding.iter().map(|f| f.entry.clone()).collect();
    let minter_state = req.minter.to_state()?;
    let seed_state = argent_runtime::state! {
        owner: bytes32(&req.seed_owner, "seedOwner")?.to_vec(),
        extension_commitment: vec![0u8; 32]
    };
    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new();
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context
            .actor_genesis_output(0, "launch::kusdt", "BridgeMint", minter_state.clone(), req.minter_value)
            .actor_genesis_output(0, "launch::kusdt", "TokenSeed", seed_state.clone(), req.seed_value);
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder()?, &req.common, entries, req.minter_value + req.seed_value, &make)?;
    let covenant_id = tx.outputs[0].covenant.map(|c| c.covenant_id);
    Ok(describe(&tx, fee, mass, covenant_id, &[("minter", None, Some(req.minter.clone())), ("seed", None, None)]))
}

// ---------------------------------------------------------------------------
// Mint

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecipientJson {
    #[serde(deserialize_with = "crate::model::int::de")]
    pub owner_scheme: u8,
    pub owner: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub amount: i64,
}

impl RecipientJson {
    pub fn to_recipient(&self) -> Result<MintRecipient, String> {
        Ok(MintRecipient { owner_scheme: self.owner_scheme, owner: bytes32(&self.owner, "owner")?, amount: self.amount })
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MintRequest {
    #[serde(flatten)]
    pub common: Common,
    pub minter: Located<MinterState>,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub chain: u8,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub first_nonce: i64,
    /// The age of the minter UTXO this mint claims: the input's sequence, which consensus
    /// checks, and part of what the signers signed.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub age_daa: i64,
    pub recipients: Vec<RecipientJson>,
    pub signer_keys: Vec<String>,
    pub signer_indices: Vec<u8>,
    pub signatures: Vec<String>,
    /// KAS carried by each minted state (it pays its storage mass). At least `protocol::MIN_MINTED_VALUE`.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
}

/// A claimed age as the input's sequence: a relative lock has 32 bits, and the script refuses anything outside them.
fn age_sequence(age_daa: i64) -> Result<u64, String> {
    if !(0..(1i64 << 32)).contains(&age_daa) {
        return Err(format!("ageDaa {age_daa} is not between 0 and 2^32 - 1"));
    }
    Ok(age_daa as u64)
}

/// The successor state BridgeMint will demand, or why it would refuse.
pub fn next_minter(state: &MinterState, chain: u8, first_nonce: i64, age_daa: i64, recipients: &[MintRecipient]) -> Result<MinterState, String> {
    if state.paused {
        return Err("minting is paused".into());
    }
    if recipients.is_empty() || recipients.len() > protocol::MAX_MINTS {
        return Err(format!("a mint has 1 to {} recipients", protocol::MAX_MINTS));
    }
    if recipients.iter().any(|r| r.amount <= 0) {
        return Err("every minted amount is positive".into());
    }
    // Checked: amounts that sum past a 64-bit number are an error here, as they are a refusal in the script.
    let total = recipients.iter().try_fold(0i64, |sum, r| sum.checked_add(r.amount)).ok_or("the minted amounts sum past the largest amount there is")?;
    let mut next = state.clone();
    match chain {
        protocol::CHAIN_ETHEREUM if first_nonce == state.nonce_ethereum => next.nonce_ethereum += recipients.len() as i64,
        protocol::CHAIN_BSC if first_nonce == state.nonce_bsc => next.nonce_bsc += recipients.len() as i64,
        protocol::CHAIN_ETHEREUM | protocol::CHAIN_BSC => return Err(format!("the next nonce to mint on chain {chain} is not {first_nonce}")),
        _ => return Err(format!("unknown chain {chain}")),
    }
    age_sequence(age_daa)?;
    let available = state.refilled(age_daa);
    if total > available {
        return Err(format!("{total} exceeds the mint allowance of {available} at a claimed age of {age_daa}"));
    }
    if total > state.remaining {
        return Err(format!("{total} exceeds the remaining cap {}", state.remaining));
    }
    next.remaining -= total;
    next.bucket = available - total;
    Ok(next)
}

pub fn mint(req: &MintRequest) -> Result<Built, String> {
    let recipients = req.recipients.iter().map(RecipientJson::to_recipient).collect::<Result<Vec<_>, _>>()?;
    // The minter's own floor (bridge_mint.ag MIN_MINTED_VALUE), said here in words before the script says it as a failure.
    if req.token_value < protocol::MIN_MINTED_VALUE {
        return Err(format!(
            "tokenValue {} is below {} sompi (1 KAS): the minter refuses a minted output that carries less",
            req.token_value,
            protocol::MIN_MINTED_VALUE
        ));
    }
    let next = next_minter(&req.minter.state, req.chain, req.first_nonce, req.age_daa, &recipients)?;
    let sequence = age_sequence(req.age_daa)?;
    let (keys, indices, signatures) = quorum_args(&req.signer_keys, &req.signer_indices, &req.signatures, protocol::MINT_QUORUM)?;
    let tokens: Vec<TokenState> = recipients.iter().map(|r| TokenState::plain(r.owner_scheme, &r.owner, r.amount)).collect();
    let token_states = tokens.iter().map(TokenState::to_state).collect::<Result<Vec<_>, _>>()?;

    let minter_entry = req.minter.utxo.entry()?;
    let covenant = minter_entry.covenant_id.ok_or("the minter UTXO carries no covenant ID")?;
    let funding = funding_inputs(&req.common.funding)?;
    check_claim(&req.minter.utxo, sequence)?;
    check_settled_inputs(&req.minter.utxo, &req.common.funding.iter().map(|f| &f.utxo).collect::<Vec<_>>())?;
    let mut entries = vec![minter_entry.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let minter_outpoint = req.minter.utxo.outpoint()?;
    let current = req.minter.state.to_state()?;
    let successor = next.to_state()?;
    let outputs_total = minter_entry.amount + req.token_value * tokens.len() as u64;

    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let call = EntryCall::new("mint").args(args!(
            req.chain,
            req.first_nonce,
            req.age_daa,
            token_states.clone(),
            keys.clone(),
            indices.clone(),
            signatures.clone()
        ));
        // The minter input's sequence is the relative lock that proves the claimed age.
        let mut context = TxContext::new()
            .actor_input("BridgeMint", current.clone(), call, minter_outpoint, minter_entry.clone(), sequence);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("BridgeMint", successor.clone(), CovenantBinding::new(0, covenant), minter_entry.amount);
        for state in &token_states {
            context = context.actor_output("KCC20", state.clone(), CovenantBinding::new(0, covenant), req.token_value);
        }
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder()?, &req.common, entries, outputs_total, &make)?;
    let mut kinds = vec![("minter", None, Some(next))];
    kinds.extend(tokens.into_iter().map(|t| ("token", Some(t), None)));
    Ok(describe(&tx, fee, mass, Some(covenant), &kinds))
}

// ---------------------------------------------------------------------------
// KCC-20 transfers (sends, redemptions)

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenInput {
    pub utxo: Utxo,
    pub state: TokenState,
    /// Owner key; only p2pk-schnorr owners (0x00) are signed here.
    pub secret_key: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenOutput {
    pub state: TokenState,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub value: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RedeemJson {
    #[serde(deserialize_with = "crate::model::int::de")]
    pub output_index: u8,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub chain: u8,
    /// 20-byte EVM address, hex.
    pub address: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferRequest {
    #[serde(flatten)]
    pub common: Common,
    pub inputs: Vec<TokenInput>,
    pub outputs: Vec<TokenOutput>,
    /// Redemptions among the outputs; their preimages go into the payload.
    #[serde(default)]
    pub redeem: Vec<RedeemJson>,
}

fn evm_address(text: &str) -> Result<[u8; 20], String> {
    let bytes = hex::decode(text)?;
    bytes.try_into().map_err(|b: Vec<u8>| format!("an EVM address has 20 bytes, not {}", b.len()))
}

pub fn transfer(req: &TransferRequest) -> Result<Built, String> {
    if req.inputs.is_empty() || req.inputs.len() > 3 || req.outputs.is_empty() || req.outputs.len() > 3 {
        return Err("a KCC-20 transfer has 1 to 3 token inputs and 1 to 3 token outputs".into());
    }
    let input_total: i64 = req.inputs.iter().map(|i| i.state.amount).sum();
    let output_total: i64 = req.outputs.iter().map(|o| o.state.amount).sum();
    if input_total != output_total {
        return Err(format!("token inputs hold {input_total}, outputs {output_total}: they must match"));
    }
    let mut redeems = Vec::new();
    for r in &req.redeem {
        // The bridge has a vault on these two chains only, and no vault pays the zero address: such a burn is never paid.
        if protocol::chain_name(r.chain).is_none() {
            return Err(format!("a redemption names chain {}: the bridge pays out on chain 1 (Ethereum) and 2 (BNB Chain) only", r.chain));
        }
        let address = evm_address(&r.address)?;
        if address == [0; 20] {
            return Err("a redemption names the zero address, which no vault pays".into());
        }
        let output = req.outputs.get(r.output_index as usize).ok_or("a redemption names a missing output")?;
        if output.state.owner_scheme != protocol::OWNER_P2SH || bytes32(&output.state.owner, "owner")? != protocol::burn_owner(r.chain, &address) {
            return Err(format!("output {} is not the burn owner for that chain and address", r.output_index));
        }
        redeems.push(RedeemEntry { output_index: r.output_index, chain: r.chain, address });
    }
    // A burn never moves again, and the signers pay one only when it is plain and holds kUSDT: borrowing off, a zero
    // borrow guard and extension commitment, an amount above zero (SPEC §9). Any other output to a burn owner named
    // here would be kUSDT lost for good with nothing paid for it.
    let burn_owners: Vec<[u8; 32]> = redeems.iter().map(|r| protocol::burn_owner(r.chain, &r.address)).collect();
    for (index, output) in req.outputs.iter().enumerate() {
        let s = &output.state;
        if s.owner_scheme == protocol::OWNER_P2SH
            && burn_owners.contains(&bytes32(&s.owner, "owner")?)
            && (s.borrow_scheme != 0 || bytes32(&s.borrow_guard, "borrowGuard")? != [0; 32] || bytes32(&s.extension_commitment, "extensionCommitment")? != [0; 32] || s.amount <= 0)
        {
            return Err(format!(
                "output {index} is a burn no signer would pay: a burn has borrowing off, a zero borrow guard and extension commitment, and an amount above zero"
            ));
        }
    }
    let payload = if redeems.is_empty() { Vec::new() } else { protocol::redeem_payload(&redeems)? };

    let mut token_inputs = Vec::new();
    for input in &req.inputs {
        if input.state.owner_scheme != protocol::OWNER_P2PK_SCHNORR {
            return Err("only p2pk-schnorr token owners are signed by this builder".into());
        }
        let entry = input.utxo.entry()?;
        let key = keypair(&input.secret_key)?;
        if key.x_only_public_key().0.serialize() != bytes32(&input.state.owner, "owner")? {
            return Err("a secret key does not own its token input".into());
        }
        token_inputs.push((input.utxo.outpoint()?, entry, input.state.to_state()?, key));
    }
    let covenant = token_inputs[0].1.covenant_id.ok_or("a token input carries no covenant ID")?;
    if token_inputs.iter().any(|(_, e, _, _)| e.covenant_id != Some(covenant)) {
        return Err("every token input must belong to the same token".into());
    }
    let next_states = req.outputs.iter().map(|o| o.state.to_state()).collect::<Result<Vec<_>, _>>()?;
    let funding = funding_inputs(&req.common.funding)?;
    let mut entries: Vec<_> = token_inputs.iter().map(|(_, e, _, _)| e.clone()).collect();
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let outputs_total: u64 = req.outputs.iter().map(|o| o.value).sum();

    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new().payload(payload.clone());
        for (position, (outpoint, entry, state, key)) in token_inputs.iter().enumerate() {
            let key = *key;
            let call = if position == 0 {
                let next_states = next_states.clone();
                EntryCall::new("transfer").args_with(move |tx, index| {
                    let mut witness = vec![0x00];
                    witness.extend(schnorr_tx_signature(tx, index, &key));
                    args!(next_states.clone(), witness)
                })
            } else {
                EntryCall::new("transfer_delegator").args_with(move |tx, index| args!(schnorr_tx_signature(tx, index, &key)))
            };
            context = context.actor_input("KCC20", state.clone(), call, *outpoint, entry.clone(), 0);
        }
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        for (state, output) in next_states.iter().zip(&req.outputs) {
            context = context.actor_output("KCC20", state.clone(), CovenantBinding::new(0, covenant), output.value);
        }
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder()?, &req.common, entries, outputs_total, &make)?;
    let kinds: Vec<_> = req.outputs.iter().map(|o| ("token", Some(o.state.clone()), None)).collect();
    Ok(describe(&tx, fee, mass, Some(covenant), &kinds))
}

// ---------------------------------------------------------------------------
// Pause and governance

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PauseRequest {
    #[serde(flatten)]
    pub common: Common,
    pub minter: Located<MinterState>,
    pub guardian_secret_key: String,
}

pub fn pause(req: &PauseRequest) -> Result<Built, String> {
    let mut next = req.minter.state.clone();
    next.paused = true;
    // A pause voids every 4-of-5 signature made before it (bridge_mint.ag, pause).
    next.admin_nonce += 1;
    let guardian = keypair(&req.guardian_secret_key)?;
    governance_tx(&req.common, &req.minter, next, None, 0, move || {
        EntryCall::new("pause").args_with(move |tx, index| args!(schnorr_tx_signature(tx, index, &guardian)))
    })
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum ActionJson {
    Unpause,
    SetLimits {
        #[serde(deserialize_with = "crate::model::int::de")]
        capacity: i64,
        #[serde(deserialize_with = "crate::model::int::de")]
        refill_per_daa: i64,
    },
    SetSigners { signer_keys: Vec<String>, guardian: String },
    SkipNonce {
        #[serde(deserialize_with = "crate::model::int::de")]
        chain: u8,
        #[serde(deserialize_with = "crate::model::int::de")]
        nonce: i64,
    },
    SetValue {
        #[serde(deserialize_with = "crate::model::int::de")]
        value: i64,
    },
    ProposeRecovery { signer_keys: Vec<String>, guardian: String },
    VetoRecovery,
}

impl ActionJson {
    pub fn to_action(&self) -> Result<GovernAction, String> {
        Ok(match self {
            Self::Unpause => GovernAction::Unpause,
            Self::SetLimits { capacity, refill_per_daa } => GovernAction::SetLimits { capacity: *capacity, refill_per_daa: *refill_per_daa },
            Self::SetSigners { signer_keys, guardian } => {
                let keys = signer_keys.iter().map(|k| bytes32(k, "signerKeys")).collect::<Result<Vec<_>, _>>()?;
                GovernAction::SetSigners { signer_set: protocol::signer_set_of(&keys)?, guardian: bytes32(guardian, "guardian")? }
            }
            Self::SkipNonce { chain, nonce } => GovernAction::SkipNonce { chain: *chain, nonce: *nonce },
            Self::SetValue { value } => GovernAction::SetValue { value: *value },
            Self::ProposeRecovery { signer_keys, guardian } => {
                let keys = signer_keys.iter().map(|k| bytes32(k, "signerKeys")).collect::<Result<Vec<_>, _>>()?;
                GovernAction::ProposeRecovery { signer_set: protocol::signer_set_of(&keys)?, guardian: bytes32(guardian, "guardian")? }
            }
            Self::VetoRecovery => GovernAction::VetoRecovery,
        })
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GovernRequest {
    #[serde(flatten)]
    pub common: Common,
    pub minter: Located<MinterState>,
    pub action: ActionJson,
    /// The age of the minter UTXO this spend claims, which settles the allowance (the spend restarts it).
    /// It is the age the signers signed (`govern-digest`'s `ageDaa`): any other fails their signatures.
    /// Absent means 0: always valid, and refills nothing.
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::opt")]
    pub age_daa: Option<i64>,
    pub signer_keys: Vec<String>,
    pub signer_indices: Vec<u8>,
    pub signatures: Vec<String>,
}

pub fn govern(req: &GovernRequest) -> Result<Built, String> {
    let action = req.action.to_action()?;
    let (keys, indices, signatures) = quorum_args(&req.signer_keys, &req.signer_indices, &req.signatures, action.quorum())?;
    let state = &req.minter.state;
    let mut next = state.clone();
    if !action.is_recovery() {
        next.admin_nonce += 1;
    }
    let age_daa = req.age_daa.unwrap_or(0);
    let sequence = age_sequence(age_daa)?;
    next.bucket = state.refilled(age_daa);
    let mut new_value = None;
    match &action {
        GovernAction::Unpause => {
            if !state.paused {
                return Err("the minter is not paused".into());
            }
            next.paused = false;
        }
        GovernAction::SetLimits { capacity, refill_per_daa } => {
            if *capacity > MAX_LIMIT || *refill_per_daa > MAX_LIMIT {
                return Err(format!("limits above {MAX_LIMIT} are refused by the minter"));
            }
            next.bucket = next.bucket.min(*capacity);
            next.capacity = *capacity;
            next.refill_per_daa = *refill_per_daa;
        }
        GovernAction::SetSigners { signer_set, guardian } => {
            next.signer_set = hex::encode(signer_set);
            next.guardian = hex::encode(guardian);
            next.clear_recovery();
            next.recovery_nonce += 1;
        }
        GovernAction::ProposeRecovery { signer_set, guardian } => {
            if state.recovery_pending {
                return Err("a recovery is already proposed: it must be vetoed before another".into());
            }
            next.recovery_pending = true;
            next.recovery_signer_set = hex::encode(signer_set);
            next.recovery_guardian = hex::encode(guardian);
            next.recovery_nonce += 1;
        }
        GovernAction::VetoRecovery => {
            if !state.recovery_pending {
                return Err("no recovery is proposed".into());
            }
            next.clear_recovery();
            next.recovery_nonce += 1;
        }
        GovernAction::SkipNonce { chain, nonce } => match *chain {
            protocol::CHAIN_ETHEREUM if *nonce == state.nonce_ethereum => next.nonce_ethereum += 1,
            protocol::CHAIN_BSC if *nonce == state.nonce_bsc => next.nonce_bsc += 1,
            _ => return Err(format!("nonce {nonce} on chain {chain} is not the next one to mint")),
        },
        GovernAction::SetValue { value } => {
            if *value <= 0 {
                return Err("the minter's KAS deposit must be positive".into());
            }
            new_value = Some(*value as u64);
        }
    }
    let params = action.params()?;
    let code = action.code();
    let entry = || EntryCall::new("govern").args(args!(code, params.clone(), age_daa, keys.clone(), indices.clone(), signatures.clone()));
    governance_tx(&req.common, &req.minter, next, new_value, sequence, entry)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteRecoveryRequest {
    #[serde(flatten)]
    pub common: Common,
    pub minter: Located<MinterState>,
}

/// Carries out a proposed recovery. Needs no signature; the input's sequence is the relative
/// lock that makes consensus hold it back until the minter UTXO is `recovery_delay` old.
pub fn execute_recovery(req: &ExecuteRecoveryRequest) -> Result<Built, String> {
    let state = &req.minter.state;
    if !state.recovery_pending {
        return Err("no recovery is proposed".into());
    }
    let mut next = state.clone();
    next.signer_set = state.recovery_signer_set.clone();
    next.guardian = state.recovery_guardian.clone();
    next.admin_nonce += 1;
    next.recovery_nonce += 1;
    next.clear_recovery();
    governance_tx(&req.common, &req.minter, next, None, state.recovery_delay as u64, || EntryCall::new("execute_recovery"))
}

/// A transition of BridgeMint alone (plus funding and change).
fn governance_tx<'a>(
    common: &Common,
    minter: &Located<MinterState>,
    next: MinterState,
    new_value: Option<u64>,
    sequence: u64,
    entry: impl Fn() -> EntryCall<'a>,
) -> Result<Built, String> {
    let minter_entry = minter.utxo.entry()?;
    let covenant = minter_entry.covenant_id.ok_or("the minter UTXO carries no covenant ID")?;
    let outpoint = minter.utxo.outpoint()?;
    let funding = funding_inputs(&common.funding)?;
    check_claim(&minter.utxo, sequence)?;
    check_settled_inputs(&minter.utxo, &common.funding.iter().map(|f| &f.utxo).collect::<Vec<_>>())?;
    let mut entries = vec![minter_entry.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let current = minter.state.to_state()?;
    let successor = next.to_state()?;
    let value = new_value.unwrap_or(minter_entry.amount);
    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new()
            .actor_input("BridgeMint", current.clone(), entry(), outpoint, minter_entry.clone(), sequence);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("BridgeMint", successor.clone(), CovenantBinding::new(0, covenant), value);
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder()?, common, entries, value, &make)?;
    Ok(describe(&tx, fee, mass, Some(covenant), &[("minter", None, Some(next))]))
}

/// The locking script of a covenant state: `actor` is "KCC20" or "BridgeMint"
/// (kUSDT app) or "Pool" or "Position" (pool app); `state` is that actor's
/// state as JSON. A wallet uses it to find, and verify, the UTXO of a state.
pub fn covenant_script(actor: &str, state: &serde_json::Value) -> Result<ScriptPublicKey, String> {
    let parse_err = |e: serde_json::Error| format!("state: {e}");
    let (builder, state) = match actor {
        "KCC20" => (builder()?, serde_json::from_value::<TokenState>(state.clone()).map_err(parse_err)?.to_state()?),
        "BridgeMint" => (builder()?, serde_json::from_value::<MinterState>(state.clone()).map_err(parse_err)?.to_state()?),
        "Pool" => (
            crate::pool::pool_builder()?,
            serde_json::from_value::<crate::pool::PoolState>(state.clone()).map_err(parse_err)?.to_state()?,
        ),
        "Position" => (
            crate::pool::pool_builder()?,
            serde_json::from_value::<crate::pool::PositionState>(state.clone()).map_err(parse_err)?.to_state()?,
        ),
        other => return Err(format!("unknown actor {other:?}")),
    };
    let utxo = builder.covenant_utxo(actor, state, 0, 0, false, None).map_err(|e| e.to_string())?;
    Ok(utxo.script_public_key)
}
