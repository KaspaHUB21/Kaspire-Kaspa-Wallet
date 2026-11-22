//! One JSON-in, JSON-out entry point for every builder and helper, shared by
//! the `kusdt-tx` CLI and the WebAssembly module.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    hex,
    model::bytes32,
    pool, protocol,
    tx::{self, ActionJson, RecipientJson},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MintDigestRequest {
    covenant_id: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    chain: u8,
    #[serde(deserialize_with = "crate::model::int::de")]
    first_nonce: i64,
    /// The age of the minter UTXO the mint claims: signed with the rest. Absent means 0.
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::de")]
    age_daa: i64,
    recipients: Vec<RecipientJson>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GovernDigestRequest {
    covenant_id: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    admin_nonce: i64,
    /// The age of the minter UTXO the governance spend claims: signed with the rest, so the transaction must claim
    /// exactly it. Absent means 0 (always valid, credits no refill).
    #[serde(default)]
    #[serde(deserialize_with = "crate::model::int::de")]
    age_daa: i64,
    action: ActionJson,
    /// The outpoint of the minter coin the action spends. An unpause signs it (and needs it here); no other action does.
    #[serde(default)]
    outpoint: Option<OutpointJson>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OutpointJson {
    transaction_id: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    index: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BurnOwnerRequest {
    #[serde(deserialize_with = "crate::model::int::de")]
    chain: u8,
    address: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignerSetRequest {
    signer_keys: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
enum QuoteRequest {
    Buy {
        pool: pool::PoolState,
        #[serde(deserialize_with = "crate::model::int::de")]
        kas_in: i64,
    },
    Sell {
        pool: pool::PoolState,
        #[serde(deserialize_with = "crate::model::int::de")]
        tokens_in: i64,
        /// With a DAA score, the answer also gives what the circuit breaker allows then.
        #[serde(default, deserialize_with = "crate::model::int::opt")]
        now_daa: Option<i64>,
        /// The DAA score the pool UTXO was accepted at (for the breaker's clock); absent counts as no time.
        #[serde(default, deserialize_with = "crate::model::int::opt")]
        pool_daa: Option<u64>,
    },
    Add {
        pool: pool::PoolState,
        #[serde(deserialize_with = "crate::model::int::de")]
        kas_in: i64,
        #[serde(deserialize_with = "crate::model::int::de")]
        tokens_in: i64,
    },
    Remove {
        pool: pool::PoolState,
        #[serde(deserialize_with = "crate::model::int::de")]
        shares: i64,
    },
}

/// A covenant state's locking script, so a wallet can find (and verify) the
/// UTXO that holds it.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScriptRequest {
    /// "KCC20", "BridgeMint" (kUSDT app) or "Pool", "Position" (pool app).
    actor: String,
    state: Value,
}

fn parse<T: for<'de> Deserialize<'de>>(input: &str) -> Result<T, String> {
    serde_json::from_str(input).map_err(|e| format!("bad request: {e}"))
}

fn to_value<T: serde::Serialize>(value: &T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|e| e.to_string())
}

pub const COMMANDS: &[&str] = &[
    "prepare", "split", "genesis", "mint", "transfer", "pause", "govern", "execute-recovery",
    "pool-genesis", "pool-init", "pool-buy", "pool-sell", "pool-add", "pool-remove", "pool-tick", "pool-collect", "pool-pause", "pool-unpause",
    "pool-set-keys", "position-transfer",
    "mint-digest", "govern-digest", "burn-owner", "signer-set", "quote", "script", "template", "layout",
];

/// Every actor's program layout (prefix ‖ state ‖ suffix) and dispatch tags,
/// so callers decode signature scripts from the artifacts instead of copies.
fn layout() -> Value {
    let mut contracts = serde_json::Map::new();
    // The pool artifact carries the kUSDT actors too; the kUSDT artifact wins.
    for artifact in [pool::pool_artifact(), tx::artifact()] {
        for (name, c) in &artifact.sil_abi.contracts {
            let code = &c.compiled.bytecode;
            let span = c.compiled.state_span;
            let entries: serde_json::Map<String, Value> =
                c.entries.iter().map(|(entry, e)| (entry.clone(), json!(hex::encode(e.dispatch_tag.as_bytes())))).collect();
            contracts.insert(name.clone(), json!({
                "templateHash": hex::encode(&c.compiled.template_hash),
                "prefix": hex::encode(&code[..span.offset]),
                "stateLength": span.len,
                "suffix": hex::encode(&code[span.offset + span.len..]),
                "entries": entries,
            }));
        }
    }
    json!({ "contracts": contracts })
}

pub fn run(command: &str, input: &str) -> Result<Value, String> {
    match command {
        "prepare" => to_value(&tx::prepare(&parse(input)?)?),
        "split" => to_value(&tx::split(&parse(input)?)?),
        "genesis" => to_value(&tx::genesis(&parse(input)?)?),
        "mint" => to_value(&tx::mint(&parse(input)?)?),
        "transfer" => to_value(&tx::transfer(&parse(input)?)?),
        "pause" => to_value(&tx::pause(&parse(input)?)?),
        "govern" => to_value(&tx::govern(&parse(input)?)?),
        "execute-recovery" => to_value(&tx::execute_recovery(&parse(input)?)?),
        "pool-genesis" => to_value(&pool::genesis(&parse(input)?)?),
        "pool-init" => to_value(&pool::init(&parse(input)?)?),
        "pool-buy" => to_value(&pool::buy(&parse(input)?)?),
        "pool-sell" => to_value(&pool::sell(&parse(input)?)?),
        "pool-add" => to_value(&pool::add(&parse(input)?)?),
        "pool-remove" => to_value(&pool::remove(&parse(input)?)?),
        "pool-tick" => to_value(&pool::tick(&parse(input)?)?),
        "pool-collect" => to_value(&pool::collect(&parse(input)?)?),
        "pool-pause" => to_value(&pool::pause(&parse(input)?)?),
        "pool-unpause" => to_value(&pool::unpause(&parse(input)?)?),
        "pool-set-keys" => to_value(&pool::set_keys(&parse(input)?)?),
        "position-transfer" => to_value(&pool::transfer_position(&parse(input)?)?),
        "mint-digest" => {
            let req: MintDigestRequest = parse(input)?;
            let recipients = req.recipients.iter().map(RecipientJson::to_recipient).collect::<Result<Vec<_>, _>>()?;
            let digest = protocol::mint_digest(&bytes32(&req.covenant_id, "covenantId")?, req.chain, req.first_nonce, req.age_daa, &recipients)?;
            Ok(json!({ "digest": hex::encode(&digest) }))
        }
        "govern-digest" => {
            let req: GovernDigestRequest = parse(input)?;
            let action = req.action.to_action()?;
            let outpoint = match &req.outpoint {
                Some(o) => Some(protocol::Outpoint { transaction_id: bytes32(&o.transaction_id, "outpoint.transactionId")?, index: o.index }),
                None => None,
            };
            // The same bound the builder puts on a claimed age (a relative lock has 32 bits): no digest for an age no spend can claim.
            if !(0..(1i64 << 32)).contains(&req.age_daa) {
                return Err(format!("ageDaa {} is not between 0 and 2^32 - 1", req.age_daa));
            }
            let digest = protocol::govern_digest(&bytes32(&req.covenant_id, "covenantId")?, req.admin_nonce, req.age_daa, &action, outpoint.as_ref())?;
            // `ageDaa` is echoed: it is part of what is signed, and every signer must sign the same one.
            Ok(json!({ "digest": hex::encode(&digest), "quorum": action.quorum(), "params": hex::encode(&action.params()?), "ageDaa": req.age_daa.to_string() }))
        }
        "burn-owner" => {
            let req: BurnOwnerRequest = parse(input)?;
            let address: [u8; 20] = hex::decode(&req.address)?.try_into().map_err(|_| "an EVM address has 20 bytes")?;
            Ok(json!({
                "ownerScheme": protocol::OWNER_P2SH,
                "owner": hex::encode(&protocol::burn_owner(req.chain, &address)),
                "script": hex::encode(&protocol::burn_script(req.chain, &address)),
            }))
        }
        "signer-set" => {
            let req: SignerSetRequest = parse(input)?;
            let keys = req.signer_keys.iter().map(|k| bytes32(k, "signerKeys")).collect::<Result<Vec<_>, _>>()?;
            Ok(json!({ "signerSet": hex::encode(&protocol::signer_set_of(&keys)?) }))
        }
        "quote" => {
            let quote: QuoteRequest = parse(input)?;
            // A quote is of an amount of zero or more on an opened pool (`PoolState::check_open`): below zero, an amount
            // less its fee can cancel a reserve in the formula's denominator.
            let (state, amounts) = match &quote {
                QuoteRequest::Buy { pool, kas_in } => (pool, vec![("kasIn", *kas_in)]),
                QuoteRequest::Sell { pool, tokens_in, .. } => (pool, vec![("tokensIn", *tokens_in)]),
                QuoteRequest::Add { pool, kas_in, tokens_in } => (pool, vec![("kasIn", *kas_in), ("tokensIn", *tokens_in)]),
                QuoteRequest::Remove { pool, shares } => (pool, vec![("shares", *shares)]),
            };
            state.check_open()?;
            if let Some((name, amount)) = amounts.iter().find(|(_, amount)| *amount < 0) {
                return Err(format!("{name} {amount} is below zero"));
            }
            Ok(match quote {
                QuoteRequest::Buy { pool, kas_in } => json!({ "tokensOut": pool::buy_quote(&pool, kas_in) }),
                QuoteRequest::Sell { pool, tokens_in, now_daa, pool_daa } => {
                    let kas_out = pool::sell_quote(&pool, tokens_in);
                    match now_daa {
                        Some(now) => {
                            let elapsed = pool::elapsed_for(&pool, now, pool_daa.unwrap_or(0));
                            let (left, ends) = pool::sell_capacity(&pool, elapsed, now);
                            // While more than half of the cap is in use a sell claims at least minAgeDaa, so it can be sent
                            // from readyAtDaa on (null while the pool UTXO is only in the mempool and a claim is needed).
                            let breaker = json!({
                                "maxKasOut": left, "windowEndsDaa": ends, "allowed": kas_out <= left,
                                "minAgeDaa": pool::least_claim(&pool), "readyAtDaa": pool::ready_at(&pool, pool_daa.unwrap_or(0)),
                            });
                            json!({ "kasOut": kas_out, "breaker": breaker, "paused": pool.paused })
                        }
                        None => json!({ "kasOut": kas_out, "paused": pool.paused }),
                    }
                }
                QuoteRequest::Add { pool, kas_in, tokens_in } => json!({ "shares": pool::add_quote(&pool, kas_in, tokens_in) }),
                QuoteRequest::Remove { pool, shares } => {
                    let (kas, tokens) = pool::remove_quote(&pool, shares);
                    json!({ "kasOut": kas, "tokensOut": tokens })
                }
            })
        }
        "script" => {
            let req: ScriptRequest = parse(input)?;
            let spk = tx::covenant_script(&req.actor, &req.state)?;
            Ok(json!({ "scriptPublicKey": crate::model::spk_to_hex(&spk) }))
        }
        "template" => {
            let (prefix, suffix) = crate::kcc20_wallet_template(tx::artifact(), "KCC20").ok_or("no KCC20 contract")?;
            let hash = &tx::artifact().sil_abi.contracts["KCC20"].compiled.template_hash;
            Ok(json!({ "templateHash": hex::encode(hash.as_ref()), "prefix": hex::encode(&prefix), "suffix": hex::encode(&suffix) }))
        }
        "layout" => Ok(layout()),
        other => Err(format!("unknown command {other:?}; commands: {}", COMMANDS.join(", "))),
    }
}
