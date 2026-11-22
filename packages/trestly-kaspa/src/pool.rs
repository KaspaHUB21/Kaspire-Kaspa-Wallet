//! Transaction builders for KasPool (`contracts/pool.ag`): genesis, the first
//! deposit, buys, sells (under the circuit breaker), liquidity in and out, the
//! breaker's tick, fee collection, the guardian's pause, the admin's unpause
//! and key changes, and position transfers.
//!
//! Every pool transaction spends the Pool UTXO together with the pool's kUSDT
//! reserve state (a second covenant family), so these builders use an
//! artifact bundle of both apps. Input and output order is the one the pool's
//! `observes` clauses expect; the covenant scripts check it.

use std::sync::OnceLock;

use argent_artifact::Artifact;
use argent_runtime::{ArtifactBundle, EntryCall, TxBuilder, TxContext, args, state};
use kaspa_consensus_core::{
    Hash,
    tx::{CovenantBinding, ScriptPublicKey},
};
use serde::{Deserialize, Serialize};

use crate::{
    model::{Built, Located, State, TokenState, Utxo, bytes32, zero32},
    protocol,
    tx::{self, Common, check_owner_key, check_settled_inputs, describe, finish, funding_inputs, keypair, p2pk_sig_script, schnorr_tx_signature},
};

pub fn pool_artifact() -> &'static Artifact {
    static ARTIFACT: OnceLock<Artifact> = OnceLock::new();
    ARTIFACT.get_or_init(|| serde_json::from_str(include_str!("../artifacts/pool.json")).expect("the checked-in pool artifact parses"))
}

pub(crate) fn pool_builder() -> Result<TxBuilder<'static>, String> {
    let bundle = ArtifactBundle::new(pool_artifact())
        .and_then(|b| b.with_artifact(tx::artifact()))
        .map_err(|e| e.to_string())?;
    TxBuilder::from_bundle(&bundle).map_err(|e| e.to_string())
}

pub const BPS: i128 = 10_000;
pub const FEE_BPS: i128 = 50;
pub const PROTOCOL_BPS: i128 = 5;
pub const MIN_LIQUIDITY: i64 = 1_000;
/// 2^61 - 1: the largest reserve, share count or amount the covenant's products accept.
pub const MAX_OPERAND: i64 = 2_305_843_009_213_693_951;
/// While more than half of the cap is in use, a public entry claims at least a window / MIN_AGE_PARTS of age.
pub const MIN_AGE_PARTS: i64 = 720;
/// The longest breaker window (DAA) a pool is made with; the shortest is 1.
pub const MAX_WINDOW_LEN: i64 = 1_000_000_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolState {
    pub token_covid: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_reserve: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_reserve: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub total_shares: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub protocol_kas: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub protocol_tokens: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub base_value: i64,
    pub admin: String,
    /// The circuit breaker (fixed at genesis): sells may take this share of the
    /// KAS reserve (basis points), refilling at one such cap per `window_len` DAA.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub max_out_bps: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub window_len: i64,
    /// The room recent buys gave sells that is still KAS those buys left in the reserve:
    /// a withdrawal moves that much back onto `window_out` (SPEC §15).
    #[serde(deserialize_with = "crate::model::int::de")]
    pub window_credit: i64,
    /// The KAS reserve the cap is measured on: set by the first deposit, then down
    /// with the reserve at once and up with claimed time.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub window_ref: i64,
    /// The allowance used so far, in net KAS: moved by sells, buys and claimed
    /// time (negative after net buying, at most one cap; never cut to a cap that shrank).
    #[serde(deserialize_with = "crate::model::int::de")]
    pub window_out: i64,
    /// Swaps and new liquidity stop while paused; withdrawals don't.
    pub paused: bool,
    /// May pause, nothing else.
    pub guardian: String,
}

impl PoolState {
    pub fn to_state(&self) -> Result<State, String> {
        Ok(state! {
            token_covid: bytes32(&self.token_covid, "tokenCovid")?.to_vec(),
            kas_reserve: self.kas_reserve,
            token_reserve: self.token_reserve,
            total_shares: self.total_shares,
            protocol_kas: self.protocol_kas,
            protocol_tokens: self.protocol_tokens,
            base_value: self.base_value,
            admin: bytes32(&self.admin, "admin")?.to_vec(),
            max_out_bps: self.max_out_bps,
            window_len: self.window_len,
            window_credit: self.window_credit,
            window_ref: self.window_ref,
            window_out: self.window_out,
            paused: self.paused,
            guardian: bytes32(&self.guardian, "guardian")?.to_vec()
        })
    }

    /// What the pool UTXO must hold.
    pub fn value(&self) -> u64 {
        (self.base_value + self.kas_reserve + self.protocol_kas) as u64
    }

    /// The reserve state's token amount.
    pub fn reserve_amount(&self) -> i64 {
        self.token_reserve + self.protocol_tokens
    }

    /// What every quote, swap, deposit, withdrawal and tick works on: a breaker window `pool-genesis` makes, which the
    /// breaker divides by, and liquidity (shares and both reserves above zero), which the quotes divide by. A pool has
    /// none before its first deposit. Any other state is refused here with the reason, where the arithmetic would
    /// otherwise stop the CLI or trap the WebAssembly module.
    pub fn check_open(&self) -> Result<(), String> {
        if !(1..=MAX_WINDOW_LEN).contains(&self.window_len) {
            return Err(format!("windowLen {} is not 1..=1 000 000 000 DAA, as pool-genesis makes it", self.window_len));
        }
        if self.total_shares <= 0 || self.kas_reserve <= 0 || self.token_reserve <= 0 {
            return Err(format!(
                "the pool holds no liquidity (totalShares {}, kasReserve {}, tokenReserve {}): it has no price before its first deposit",
                self.total_shares, self.kas_reserve, self.token_reserve
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PositionState {
    pub token_covid: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub shares: i64,
    pub owner: String,
}

impl PositionState {
    pub fn to_state(&self) -> Result<State, String> {
        Ok(state! {
            token_covid: bytes32(&self.token_covid, "tokenCovid")?.to_vec(),
            shares: self.shares,
            owner: bytes32(&self.owner, "owner")?.to_vec()
        })
    }
}

/// The reserve state of the pool `pool_id` holding `amount`.
pub fn reserve_state(pool_id: &str, amount: i64) -> TokenState {
    TokenState {
        amount,
        owner: pool_id.to_string(),
        owner_scheme: protocol::OWNER_COVENANT_ID,
        borrow_scheme: 0,
        borrow_guard: zero32(),
        extension_commitment: zero32(),
    }
}

// Quotes, exactly as the covenant checks them.

pub fn buy_quote(state: &PoolState, kas_in: i64) -> i64 {
    let eff = kas_in as i128 * (BPS - FEE_BPS) / BPS;
    (state.token_reserve as i128 * eff / (state.kas_reserve as i128 + eff)) as i64
}

pub fn sell_quote(state: &PoolState, tokens_in: i64) -> i64 {
    let eff = tokens_in as i128 * (BPS - FEE_BPS) / BPS;
    (state.kas_reserve as i128 * eff / (state.token_reserve as i128 + eff)) as i64
}

pub fn add_quote(state: &PoolState, kas_in: i64, tokens_in: i64) -> i64 {
    let by_kas = kas_in as i128 * state.total_shares as i128 / state.kas_reserve as i128;
    let by_tokens = tokens_in as i128 * state.total_shares as i128 / state.token_reserve as i128;
    by_kas.min(by_tokens) as i64
}

pub fn remove_quote(state: &PoolState, shares: i64) -> (i64, i64) {
    let kas = shares as i128 * state.kas_reserve as i128 / state.total_shares as i128;
    let tokens = shares as i128 * state.token_reserve as i128 / state.total_shares as i128;
    (kas as i64, tokens as i64)
}

/// The reference after `elapsed` DAA: down to the reserve at once, up toward it
/// by elapsed / window_len of the gap, and by at most its own size per window.
fn advanced_ref(state: &PoolState, elapsed: i64) -> i64 {
    let (reference, reserve) = (state.window_ref, state.kas_reserve);
    if reserve <= reference {
        return reserve;
    }
    let gap = (reserve - reference).min(reference);
    if elapsed < state.window_len {
        reference + (gap as i128 * elapsed as i128 / state.window_len as i128) as i64
    } else {
        reference + gap
    }
}

/// `max_out_bps` of `base`, rounded down.
fn share_of(state: &PoolState, base: i64) -> i64 {
    (base as i128 * state.max_out_bps as i128 / BPS) as i64
}

/// `used` after `elapsed` DAA at `cap` per `window_len`: it moves toward zero,
/// without crossing it. Credit is kept within one cap; a positive count is never
/// cut to a cap that shrank.
fn settled_out(state: &PoolState, used: i64, elapsed: i64, cap: i64) -> i64 {
    let used = used.max(-cap);
    let decay = (elapsed as i128 * cap as i128 / state.window_len as i128) as i64;
    if used > 0 {
        (used - decay).max(0)
    } else {
        (used + decay).min(0)
    }
}

/// What is left of `credit` once `stored` has settled to `settled`.
fn credit_left(credit: i64, stored: i64, settled: i64) -> i64 {
    if stored < 0 {
        (credit - (settled - stored)).max(0)
    } else {
        credit
    }
}

/// The breaker's clock for a transaction built at `now_daa`, spending a pool
/// UTXO accepted at `pool_daa`: the DAA its age proves it has stood, at most two
/// windows. No pool age known (a pool UTXO only in the mempool) is no time.
pub fn elapsed_for(state: &PoolState, now_daa: i64, pool_daa: u64) -> i64 {
    if pool_daa == 0 || pool_daa > i64::MAX as u64 {
        return 0;
    }
    (now_daa - pool_daa as i64).clamp(0, 2 * state.window_len)
}

/// The shortest age a public entry may claim while more than half the cap is
/// in use (`in_the_regime`), and the shortest a `tick` ever claims: a 720th of
/// the window, at least 1 DAA (50 DAA at the deployed 36 000).
pub fn min_age(state: &PoolState) -> i64 {
    (state.window_len / MIN_AGE_PARTS).max(1)
}

/// Whether more than half of the cap is in use, on the stored values, as the
/// covenant's `require_claim` decides it: `window_out > share_of(window_ref) / 2`
/// (that is `2 · window_out > cap`). Then every public entry claims at least `min_age`.
pub fn in_the_regime(state: &PoolState) -> bool {
    state.window_out > share_of(state, state.window_ref) / 2
}

/// The least a buy, sell, add (or a remove while not paused) on this state must
/// claim: `min_age` while more than half the cap is in use, else nothing.
pub fn least_claim(state: &PoolState) -> i64 {
    if in_the_regime(state) { min_age(state) } else { 0 }
}

/// The least a remove on this state must claim: none while paused (it claims
/// exactly 0 then: the breaker stands still, and the guardian's pause never
/// holds providers in), else `least_claim`.
pub fn least_remove_claim(state: &PoolState) -> i64 {
    if state.paused { 0 } else { least_claim(state) }
}

/// The age a public entry built at `now_daa` claims, on a pool UTXO accepted at
/// `pool_daa` (0 when it is only in the mempool): `elapsed_for`, or an error
/// when that is below what the covenant requires (`least` DAA). The node refuses
/// a transaction whose relative lock is not met yet (it does not hold it), and a
/// UTXO still in the mempool has no age to prove, so the caller waits for the
/// pool UTXO to be accepted and that old, then builds again.
pub fn claim_with(state: &PoolState, now_daa: i64, pool_daa: u64, least: i64) -> Result<i64, String> {
    let elapsed = elapsed_for(state, now_daa, pool_daa);
    if elapsed >= least {
        return Ok(elapsed);
    }
    if pool_daa == 0 || pool_daa > i64::MAX as u64 {
        return Err(format!(
            "the pool UTXO is not accepted yet: while more than half the cap is in use a pool transaction claims at least {least} DAA of its age, so wait until it is accepted and {least} DAA old"
        ));
    }
    Err(format!("the pool UTXO is {elapsed} DAA old and this pool transaction must claim at least {least}: build it again at DAA score {}", pool_daa as i64 + least))
}

/// The claim of a public swap or liquidity entry (`least_claim`).
pub fn claim_for(state: &PoolState, now_daa: i64, pool_daa: u64) -> Result<i64, String> {
    claim_with(state, now_daa, pool_daa, least_claim(state))
}

/// The DAA score from which a public entry may spend this pool UTXO (accepted at
/// `pool_daa`, 0 when only in the mempool, which has none): its acceptance plus
/// `least_claim`.
pub fn ready_at(state: &PoolState, pool_daa: u64) -> Option<i64> {
    if pool_daa == 0 || pool_daa > i64::MAX as u64 {
        return if least_claim(state) == 0 { Some(0) } else { None };
    }
    Some(pool_daa as i64 + least_claim(state))
}

/// The breaker after `elapsed` DAA of claimed time and nothing else, exactly as
/// `tick` computes it, and as `add` and `remove` settle it before their own
/// effect: the reference, the allowance used and the credit left.
pub fn breaker_settled(state: &PoolState, elapsed: i64) -> (i64, i64, i64) {
    let reference = advanced_ref(state, elapsed);
    let cap = share_of(state, reference);
    let used = settled_out(state, state.window_out, elapsed, cap);
    (reference, used, credit_left(state.window_credit, state.window_out, used))
}

/// The breaker a withdrawal of `kas_out` leaves, claiming `elapsed`, as the
/// covenant computes it: settled first (not at all while paused: the breaker
/// stands still then, and the claim is 0), then that much of recent buys'
/// credit back on the count, and a pool shrunk below the reference cuts the
/// count to two of its smaller caps.
pub fn breaker_after_remove(state: &PoolState, kas_out: i64, elapsed: i64) -> (i64, i64, i64) {
    let (reference, used, credit) = if state.paused { (state.window_ref, state.window_out, state.window_credit) } else { breaker_settled(state, elapsed) };
    let reclaimed = kas_out.min(credit);
    let next_x = state.kas_reserve - kas_out;
    let mut next_ref = reference;
    let mut next_out = used + reclaimed;
    if next_x < reference {
        next_ref = next_x;
        next_out = next_out.min(2 * share_of(state, next_ref));
    }
    (next_ref, next_out, credit - reclaimed)
}

/// The circuit breaker after a sell of `kas_out`, `elapsed` DAA after the pool
/// UTXO it spends was accepted, exactly as the covenant computes it: the
/// reference, the allowance used and the credit left, or why the sell is refused.
pub fn breaker_after(state: &PoolState, kas_out: i64, elapsed: i64) -> Result<(i64, i64, i64), String> {
    if !(0..=2 * state.window_len).contains(&elapsed) {
        return Err(format!("elapsed {elapsed} is outside 0..={}", 2 * state.window_len));
    }
    if elapsed < least_claim(state) {
        return Err(format!("while more than half the cap is in use a sell claims at least {} DAA of the pool UTXO's age", least_claim(state)));
    }
    let reference = advanced_ref(state, elapsed);
    let cap = share_of(state, reference);
    let used = settled_out(state, state.window_out, elapsed, cap);
    if used as i128 + kas_out as i128 > cap as i128 {
        return Err(format!(
            "the pool's circuit breaker lets sells take at most {} sompi more now; it refills by {} sompi per DAA",
            (cap - used).max(0),
            cap / state.window_len
        ));
    }
    let credit = (credit_left(state.window_credit, state.window_out, used) - kas_out).max(0);
    Ok((reference.min(state.kas_reserve - kas_out), used + kas_out, credit))
}

/// The breaker's reference, allowance and credit after a buy that adds `kas_added`
/// to the reserve, `elapsed` DAA after the pool UTXO it spends was accepted, exactly
/// as the covenant computes them: the buy gives sells that much room, at most one
/// cap, adds nothing to the reference, and records what it really credited.
pub fn breaker_after_buy(state: &PoolState, kas_added: i64, elapsed: i64) -> (i64, i64, i64) {
    let reference = advanced_ref(state, elapsed);
    let cap = share_of(state, reference);
    let settled = settled_out(state, state.window_out, elapsed, cap);
    let next = (settled - kas_added).max(-cap);
    let credit = (credit_left(state.window_credit, state.window_out, settled) as i128 + (settled - next) as i128).min(MAX_OPERAND as i128) as i64;
    (reference, next, credit)
}

/// What sells may still take out now (sompi), `elapsed` DAA after the pool UTXO
/// was accepted, and the DAA score (from `now_daa`) at which the allowance has
/// fully refilled. A sell claims at least `least_claim`, so a younger UTXO gives
/// the room a sell will have once it can be sent (`ready_at`).
pub fn sell_capacity(state: &PoolState, elapsed: i64, now_daa: i64) -> (i64, i64) {
    let elapsed = elapsed.max(least_claim(state));
    let cap = share_of(state, advanced_ref(state, elapsed));
    let used = settled_out(state, state.window_out, elapsed, cap);
    let room = (cap - used).max(0);
    let ends = if used <= 0 || cap == 0 {
        now_daa
    } else {
        now_daa + ((used as i128 * state.window_len as i128 + cap as i128 - 1) / cap as i128) as i64
    };
    (room, ends)
}

fn protocol_cut(amount: i64) -> i64 {
    (amount as i128 * PROTOCOL_BPS / BPS) as i64
}

/// A public entry's claim from an optional clock: none claims nothing, which
/// the covenant takes only while at most half of the cap is in use (or, for a
/// withdrawal, while the pool is paused).
fn claim_of(state: &PoolState, now_daa: Option<i64>, pool_daa: u64, what: &str, least: i64) -> Result<i64, String> {
    match now_daa {
        Some(now) => claim_with(state, now, pool_daa, least),
        None if least == 0 => Ok(0),
        None => Err(format!("while more than half the cap is in use a {what} claims at least {least} DAA of the pool UTXO's age: give nowDaa")),
    }
}

/// A user's token state: a p2pk-schnorr KCC20 state and its key.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnedToken {
    pub utxo: Utxo,
    pub state: TokenState,
    pub secret_key: String,
}

struct Ctx {
    pool_covenant: Hash,
    token_covenant: Hash,
}

fn ids(pool: &Located<PoolState>) -> Result<Ctx, String> {
    let entry = pool.utxo.entry()?;
    let pool_covenant = entry.covenant_id.ok_or("the pool UTXO carries no covenant ID")?;
    let token_covenant = Hash::from_bytes(bytes32(&pool.state.token_covid, "tokenCovid")?);
    Ok(Ctx { pool_covenant, token_covenant })
}

fn check_reserve(pool: &Located<PoolState>, reserve: &Located<TokenState>, ctx: &Ctx) -> Result<(), String> {
    let expected = reserve_state(&ctx.pool_covenant.to_string(), pool.state.reserve_amount());
    if reserve.state != expected {
        return Err("the reserve state does not match the pool".into());
    }
    if reserve.utxo.entry()?.covenant_id != Some(ctx.token_covenant) {
        return Err("the reserve is not a state of the pool's token".into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolGenesisRequest {
    #[serde(flatten)]
    pub common: Common,
    /// The token the pool trades against KAS (kUSDT's covenant ID).
    pub token_covid: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub base_value: i64,
    pub admin: String,
    /// x-only key that may pause the pool (the bridge's guardian).
    pub guardian: String,
    /// Share of the KAS reserve sells may take per window, in basis points (1..=10 000).
    #[serde(deserialize_with = "crate::model::int::de")]
    pub max_out_bps: i64,
    /// The breaker's window, in DAA (36 000 is an hour at 10 BPS).
    #[serde(deserialize_with = "crate::model::int::de")]
    pub window_len: i64,
}

pub fn genesis(req: &PoolGenesisRequest) -> Result<Built, String> {
    if !(1..=BPS as i64).contains(&req.max_out_bps) {
        return Err("maxOutBps must be 1..=10000".into());
    }
    if !(1..=MAX_WINDOW_LEN).contains(&req.window_len) {
        return Err("windowLen must be 1..=1 000 000 000 DAA".into());
    }
    let funding = funding_inputs(&req.common.funding)?;
    if funding.is_empty() {
        return Err("pool genesis spends at least one funding coin".into());
    }
    let entries: Vec<_> = funding.iter().map(|f| f.entry.clone()).collect();
    let state = PoolState {
        token_covid: req.token_covid.clone(),
        kas_reserve: 0,
        token_reserve: 0,
        total_shares: 0,
        protocol_kas: 0,
        protocol_tokens: 0,
        base_value: req.base_value,
        admin: req.admin.clone(),
        max_out_bps: req.max_out_bps,
        window_len: req.window_len,
        window_credit: 0,
        window_ref: 0, // set by the first deposit
        window_out: 0,
        paused: false,
        guardian: req.guardian.clone(),
    };
    let pool_state = state.to_state()?;
    let builder = pool_builder()?;
    let make = |change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new();
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_genesis_output(0, "launch::pool", "Pool", pool_state.clone(), state.value());
        if let Some((script, value)) = change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, state.value(), &make)?;
    let covenant_id = tx.outputs[0].covenant.map(|c| c.covenant_id);
    let mut built = describe(&tx, fee, mass, covenant_id, &[("pool", None, None)]);
    built.outputs[0].pool = Some(state);
    Ok(built)
}

// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub provider: OwnedToken,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_in: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub tokens_in: i64,
    /// x-only key that will own the position.
    pub position_owner: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub position_value: u64,
    /// The pool admin's secret key: the first deposit takes its signature.
    pub admin_secret_key: String,
}

/// The pool admin's key from its secret, checked against the pool's `admin`.
fn admin_keypair(state: &PoolState, secret_hex: &str) -> Result<secp256k1::Keypair, String> {
    let admin = keypair(secret_hex)?;
    if hex(&admin.x_only_public_key().0.serialize()) != state.admin {
        return Err("adminSecretKey is not the pool admin's key".into());
    }
    Ok(admin)
}

pub fn init(req: &InitRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    let s = &req.pool.state;
    if s.total_shares != 0 {
        return Err("the pool already has liquidity".into());
    }
    // pool.ag `init`: require(!paused). Said here in words: the script's refusal alone would not say why.
    if s.paused {
        return Err("the pool is paused: its admin unpauses it first (pool-unpause), and the first deposit can follow on the unpause's output".into());
    }
    // The first deposit takes the admin's signature (an open with dust leaves a reference too small to refill).
    let admin = admin_keypair(s, &req.admin_secret_key)?;
    if req.kas_in <= MIN_LIQUIDITY || req.tokens_in <= 0 || req.tokens_in > req.provider.state.amount {
        return Err("init takes more than MIN_LIQUIDITY sompi and 1..=held tokens".into());
    }
    let key = check_owner_key(&req.provider.state, &req.provider.secret_key)?;
    let pool_id = ctx.pool_covenant.to_string();
    let next = PoolState { kas_reserve: req.kas_in, token_reserve: req.tokens_in, total_shares: req.kas_in, window_ref: req.kas_in, ..s.clone() };
    let reserve = reserve_state(&pool_id, next.reserve_amount());
    let change = TokenState { amount: req.provider.state.amount - req.tokens_in, ..req.provider.state.clone() };
    let position = PositionState { token_covid: s.token_covid.clone(), shares: req.kas_in - MIN_LIQUIDITY, owner: req.position_owner.clone() };
    let (pool_in, provider_in) = (req.pool.utxo.entry()?, req.provider.utxo.entry()?);
    let funding = funding_inputs(&req.common.funding)?;
    check_settled_inputs(&req.pool.utxo, &std::iter::once(&req.provider.utxo).chain(req.common.funding.iter().map(|f| &f.utxo)).collect::<Vec<_>>())?;
    let mut entries = vec![pool_in.clone(), provider_in.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let (pool_out, provider_out) = (req.pool.utxo.outpoint()?, req.provider.utxo.outpoint()?);
    let (current, successor, position_state) = (s.to_state()?, next.to_state()?, position.to_state()?);
    let next_states = vec![reserve.to_state()?, change.to_state()?];
    let change_state = change.to_state()?;
    let outputs_total = next.value() + req.position_value + 2 * req.token_value;
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let next_states = next_states.clone();
        let (kas_in, owner, change_arg) = (req.kas_in, bytes32(&req.position_owner, "positionOwner")?.to_vec(), change_state.clone());
        let call = EntryCall::new("init").args_with(move |tx, i| args!(kas_in, owner.clone(), change_arg.clone(), schnorr_tx_signature(tx, i, &admin)));
        let leader = EntryCall::new("transfer").args_with(move |tx, i| {
            let mut witness = vec![0x00];
            witness.extend(schnorr_tx_signature(tx, i, &key));
            args!(next_states.clone(), witness)
        });
        let mut context = TxContext::new()
            .actor_input("Pool", current.clone(), call, pool_out, pool_in.clone(), 0)
            .actor_input("kusdt::KCC20", req.provider.state.to_state()?, leader, provider_out, provider_in.clone(), 0);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context
            .actor_output("Pool", successor.clone(), CovenantBinding::new(0, ctx.pool_covenant), next.value())
            .actor_output("Position", position_state.clone(), CovenantBinding::new(0, ctx.pool_covenant), req.position_value)
            .actor_output("kusdt::KCC20", reserve.to_state()?, CovenantBinding::new(1, ctx.token_covenant), req.token_value)
            .actor_output("kusdt::KCC20", change_state.clone(), CovenantBinding::new(1, ctx.token_covenant), req.token_value);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, outputs_total, &make)?;
    let mut built = describe(&tx, fee, mass, Some(ctx.pool_covenant), &[("pool", None, None), ("position", None, None), ("reserve", Some(reserve), None), ("token", Some(change), None)]);
    built.outputs[0].pool = Some(next);
    built.outputs[1].position = Some(position);
    Ok(built)
}

// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuyRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub reserve: Located<TokenState>,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_in: i64,
    /// kUSDT to receive; at most the quote.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub tokens_out: i64,
    /// x-only key (p2pk-schnorr) that receives the tokens.
    pub buyer: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
    /// A DAA score the DAG has reached: the breaker's clock for the time the pool
    /// UTXO has stood. Without it the buy claims none (it just refills nothing).
    #[serde(default, deserialize_with = "crate::model::int::opt")]
    pub now_daa: Option<i64>,
}

pub fn buy(req: &BuyRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    check_reserve(&req.pool, &req.reserve, &ctx)?;
    let s = &req.pool.state;
    s.check_open()?;
    if s.paused {
        return Err("the pool is paused: swaps and new liquidity are stopped, withdrawals stay open".into());
    }
    // Below zero, the KAS in less its fee can cancel the reserve in the quote's denominator.
    if req.kas_in <= 0 {
        return Err("kasIn must be above zero".into());
    }
    if req.tokens_out <= 0 || req.tokens_out > buy_quote(s, req.kas_in) {
        return Err(format!("{} kUSDT base units is above the quote of {} for {} sompi", req.tokens_out, buy_quote(s, req.kas_in), req.kas_in));
    }
    let cut = protocol_cut(req.kas_in);
    let elapsed = claim_of(s, req.now_daa, req.pool.utxo.block_daa_score, "buy", least_claim(s))?;
    let (window_ref, window_out, window_credit) = breaker_after_buy(s, req.kas_in - cut, elapsed);
    let next = PoolState {
        kas_reserve: s.kas_reserve + req.kas_in - cut,
        token_reserve: s.token_reserve - req.tokens_out,
        protocol_kas: s.protocol_kas + cut,
        window_credit,
        window_ref,
        window_out,
        ..s.clone()
    };
    let pool_id = ctx.pool_covenant.to_string();
    let reserve_next = reserve_state(&pool_id, next.reserve_amount());
    let bought = TokenState::plain(protocol::OWNER_P2PK_SCHNORR, &bytes32(&req.buyer, "buyer")?, req.tokens_out);
    let (kas_in, bought_state) = (req.kas_in, bought.to_state()?);
    let call = move || EntryCall::new("buy").args(args!(kas_in, elapsed, bought_state.clone()));
    swap_tx(
        &req.common,
        &req.pool,
        &req.reserve,
        &ctx,
        next,
        call,
        None,
        vec![(reserve_next, req.reserve.utxo.amount), (bought, req.token_value)],
        elapsed as u64,
    )
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SellRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub reserve: Located<TokenState>,
    pub payer: OwnedToken,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub tokens_in: i64,
    /// KAS to receive (it goes to the change address); at most the quote.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_out: i64,
    /// KAS carried by the token change state (when not selling it all).
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
    /// A DAA score the DAG has reached: the breaker's clock for the time the
    /// pool UTXO has stood.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub now_daa: i64,
}

pub fn sell(req: &SellRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    check_reserve(&req.pool, &req.reserve, &ctx)?;
    let s = &req.pool.state;
    s.check_open()?;
    if req.tokens_in <= 0 || req.tokens_in > req.payer.state.amount {
        return Err("tokensIn must be 1..=the payer state's amount".into());
    }
    if req.kas_out <= 0 || req.kas_out > sell_quote(s, req.tokens_in) {
        return Err(format!("{} sompi is above the quote of {} for {} base units", req.kas_out, sell_quote(s, req.tokens_in), req.tokens_in));
    }
    if s.paused {
        return Err("the pool is paused: swaps and new liquidity are stopped, withdrawals stay open".into());
    }
    let elapsed = claim_for(s, req.now_daa, req.pool.utxo.block_daa_score)?;
    let (window_ref, window_out, window_credit) = breaker_after(s, req.kas_out, elapsed)?;
    let cut = protocol_cut(req.tokens_in);
    let next = PoolState {
        kas_reserve: s.kas_reserve - req.kas_out,
        token_reserve: s.token_reserve + req.tokens_in - cut,
        protocol_tokens: s.protocol_tokens + cut,
        window_credit,
        window_ref,
        window_out,
        ..s.clone()
    };
    let pool_id = ctx.pool_covenant.to_string();
    let reserve_next = reserve_state(&pool_id, next.reserve_amount());
    let all = req.tokens_in == req.payer.state.amount;
    let change = TokenState { amount: req.payer.state.amount - req.tokens_in, ..req.payer.state.clone() };
    let (kas_out, change_state) = (req.kas_out, change.to_state()?);
    let call = move || {
        if all {
            EntryCall::new("sell_all").args(args!(kas_out, elapsed))
        } else {
            EntryCall::new("sell").args(args!(kas_out, elapsed, change_state.clone()))
        }
    };
    let outputs = if all {
        vec![(reserve_next, req.reserve.utxo.amount)]
    } else {
        vec![(reserve_next, req.reserve.utxo.amount), (change, req.token_value)]
    };
    swap_tx(&req.common, &req.pool, &req.reserve, &ctx, next, call, Some(&req.payer), outputs, elapsed as u64)
}

/// Pool + reserve (+ one user token as a delegate), then funding; outputs:
/// the pool, the token states in observe order, then KAS change.
#[allow(clippy::too_many_arguments)]
fn swap_tx(
    common: &Common,
    pool: &Located<PoolState>,
    reserve: &Located<TokenState>,
    ctx: &Ctx,
    next: PoolState,
    call: impl Fn() -> EntryCall<'static>,
    payer: Option<&OwnedToken>,
    token_outputs: Vec<(TokenState, u64)>,
    age_daa: u64,
) -> Result<Built, String> {
    let (pool_in, reserve_in) = (pool.utxo.entry()?, reserve.utxo.entry()?);
    let funding = funding_inputs(&common.funding)?;
    check_settled_inputs(&pool.utxo, &std::iter::once(&reserve.utxo).chain(payer.map(|p| &p.utxo)).chain(common.funding.iter().map(|f| &f.utxo)).collect::<Vec<_>>())?;
    let payer_parts = match payer {
        Some(p) => Some((p.utxo.outpoint()?, p.utxo.entry()?, p.state.to_state()?, check_owner_key(&p.state, &p.secret_key)?)),
        None => None,
    };
    let mut entries = vec![pool_in.clone(), reserve_in.clone()];
    if let Some((_, e, _, _)) = &payer_parts {
        entries.push(e.clone());
    }
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let next_states = token_outputs.iter().map(|(s, _)| s.to_state()).collect::<Result<Vec<_>, _>>()?;
    let outputs_total = next.value() + token_outputs.iter().map(|(_, v)| *v).sum::<u64>();
    let (current, successor) = (pool.state.to_state()?, next.to_state()?);
    let (pool_out, reserve_out) = (pool.utxo.outpoint()?, reserve.utxo.outpoint()?);
    let reserve_state_in = reserve.state.to_state()?;
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let next_states = next_states.clone();
        let entry = call();
        // The pool input's sequence is the relative lock that proves the
        // breaker's clock: the claimed age, which consensus checks.
        let mut context = TxContext::new()
            .actor_input("Pool", current.clone(), entry, pool_out, pool_in.clone(), age_daa)
            .actor_input(
                "kusdt::KCC20",
                reserve_state_in.clone(),
                EntryCall::new("transfer").args(args!(next_states.clone(), vec![0x00u8])),
                reserve_out,
                reserve_in.clone(),
                0,
            );
        if let Some((outpoint, entry, state, key)) = &payer_parts {
            let key = *key;
            context = context.actor_input(
                "kusdt::KCC20",
                state.clone(),
                EntryCall::new("transfer_delegator").args_with(move |tx, i| args!(schnorr_tx_signature(tx, i, &key))),
                *outpoint,
                entry.clone(),
                0,
            );
        }
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("Pool", successor.clone(), CovenantBinding::new(0, ctx.pool_covenant), next.value());
        for ((_, value), state) in token_outputs.iter().zip(&next_states) {
            context = context.actor_output("kusdt::KCC20", state.clone(), CovenantBinding::new(1, ctx.token_covenant), *value);
        }
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, common, entries, outputs_total, &make)?;
    let mut kinds = vec![("pool", None, None)];
    for (i, (state, _)) in token_outputs.into_iter().enumerate() {
        kinds.push((if i == 0 { "reserve" } else { "token" }, Some(state), None));
    }
    let mut built = describe(&tx, fee, mass, Some(ctx.pool_covenant), &kinds);
    built.outputs[0].pool = Some(next);
    Ok(built)
}

// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub reserve: Located<TokenState>,
    pub provider: OwnedToken,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_in: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub tokens_in: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub shares: i64,
    pub position_owner: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub position_value: u64,
    /// A DAA score the DAG has reached: the breaker's clock, as for a swap.
    /// Without it the add claims none, which is refused while more than half of the cap is in use.
    #[serde(default, deserialize_with = "crate::model::int::opt")]
    pub now_daa: Option<i64>,
    /// The pool admin's secret key: needed only for the first deposit into an
    /// emptied pool (only the MIN_LIQUIDITY unowned shares left).
    #[serde(default)]
    pub admin_secret_key: Option<String>,
}

pub fn add(req: &AddRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    check_reserve(&req.pool, &req.reserve, &ctx)?;
    let s = &req.pool.state;
    s.check_open()?;
    if s.paused {
        return Err("the pool is paused: swaps and new liquidity are stopped, withdrawals stay open".into());
    }
    if req.tokens_in <= 0 || req.tokens_in > req.provider.state.amount || req.kas_in <= 0 {
        return Err("add takes positive KAS and 1..=held tokens".into());
    }
    if req.shares <= 0 || req.shares > add_quote(s, req.kas_in, req.tokens_in) {
        return Err(format!("{} shares is above the {} this deposit buys", req.shares, add_quote(s, req.kas_in, req.tokens_in)));
    }
    let key = check_owner_key(&req.provider.state, &req.provider.secret_key)?;
    // Into an emptied pool, a first deposit again: the admin's signature, and the reference starts at the new reserve.
    let emptied = s.total_shares == MIN_LIQUIDITY;
    let admin = match (&req.admin_secret_key, emptied) {
        (Some(secret), true) => Some(admin_keypair(s, secret)?),
        (None, true) => return Err("the pool was emptied: only its admin can deposit into it first (adminSecretKey)".into()),
        (_, false) => None,
    };
    // The breaker settles the pool UTXO's age first, as a swap does; the new liquidity changes none of it.
    let elapsed = claim_of(s, req.now_daa, req.pool.utxo.block_daa_score, "deposit", least_claim(s))?;
    let (window_ref, window_out, window_credit) = breaker_settled(s, elapsed);
    let next = PoolState {
        kas_reserve: s.kas_reserve + req.kas_in,
        token_reserve: s.token_reserve + req.tokens_in,
        total_shares: s.total_shares + req.shares,
        window_credit,
        window_ref: if emptied { s.kas_reserve + req.kas_in } else { window_ref },
        window_out,
        ..s.clone()
    };
    let pool_id = ctx.pool_covenant.to_string();
    let reserve_next = reserve_state(&pool_id, next.reserve_amount());
    let change = TokenState { amount: req.provider.state.amount - req.tokens_in, ..req.provider.state.clone() };
    let position = PositionState { token_covid: s.token_covid.clone(), shares: req.shares, owner: req.position_owner.clone() };
    let (pool_in, reserve_in, provider_in) = (req.pool.utxo.entry()?, req.reserve.utxo.entry()?, req.provider.utxo.entry()?);
    let funding = funding_inputs(&req.common.funding)?;
    check_settled_inputs(&req.pool.utxo, &[&req.reserve.utxo, &req.provider.utxo].into_iter().chain(req.common.funding.iter().map(|f| &f.utxo)).collect::<Vec<_>>())?;
    let mut entries = vec![pool_in.clone(), reserve_in.clone(), provider_in.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let next_states = vec![reserve_next.to_state()?, change.to_state()?];
    let (current, successor, position_state) = (s.to_state()?, next.to_state()?, position.to_state()?);
    let change_state = change.to_state()?;
    let outputs_total = next.value() + req.position_value + req.reserve.utxo.amount + req.token_value;
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let (kas_in, shares, owner, change_arg) = (req.kas_in, req.shares, bytes32(&req.position_owner, "positionOwner")?.to_vec(), change_state.clone());
        let call = EntryCall::new("add").args_with(move |tx, i| {
            let witness = admin.map(|a| schnorr_tx_signature(tx, i, &a)).unwrap_or_default();
            args!(kas_in, shares, elapsed, owner.clone(), change_arg.clone(), witness)
        });
        // The pool input's sequence is the relative lock that proves the claimed age.
        let mut context = TxContext::new()
            .actor_input("Pool", current.clone(), call, req.pool.utxo.outpoint()?, pool_in.clone(), elapsed as u64)
            .actor_input("kusdt::KCC20", req.reserve.state.to_state()?, EntryCall::new("transfer").args(args!(next_states.clone(), vec![0x00u8])), req.reserve.utxo.outpoint()?, reserve_in.clone(), 0)
            .actor_input(
                "kusdt::KCC20",
                req.provider.state.to_state()?,
                EntryCall::new("transfer_delegator").args_with(move |tx, i| args!(schnorr_tx_signature(tx, i, &key))),
                req.provider.utxo.outpoint()?,
                provider_in.clone(),
                0,
            );
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context
            .actor_output("Pool", successor.clone(), CovenantBinding::new(0, ctx.pool_covenant), next.value())
            .actor_output("Position", position_state.clone(), CovenantBinding::new(0, ctx.pool_covenant), req.position_value)
            .actor_output("kusdt::KCC20", next_states[0].clone(), CovenantBinding::new(1, ctx.token_covenant), req.reserve.utxo.amount)
            .actor_output("kusdt::KCC20", change_state.clone(), CovenantBinding::new(1, ctx.token_covenant), req.token_value);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, outputs_total, &make)?;
    let mut built = describe(&tx, fee, mass, Some(ctx.pool_covenant), &[("pool", None, None), ("position", None, None), ("reserve", Some(reserve_next), None), ("token", Some(change), None)]);
    built.outputs[0].pool = Some(next);
    built.outputs[1].position = Some(position);
    Ok(built)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub reserve: Located<TokenState>,
    pub position: Located<PositionState>,
    pub position_secret_key: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub kas_out: i64,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub tokens_out: i64,
    /// x-only key that receives the tokens.
    pub receiver: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
    /// A DAA score the DAG has reached: the breaker's clock, as for a swap.
    /// Without it the withdrawal claims none, which is refused while more than half of the cap is in use (unless paused).
    #[serde(default, deserialize_with = "crate::model::int::opt")]
    pub now_daa: Option<i64>,
}

pub fn remove(req: &RemoveRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    check_reserve(&req.pool, &req.reserve, &ctx)?;
    let s = &req.pool.state;
    s.check_open()?;
    let shares = req.position.state.shares;
    let (max_kas, max_tokens) = remove_quote(s, shares);
    if req.kas_out < 0 || req.kas_out > max_kas || req.tokens_out < 0 || req.tokens_out > max_tokens {
        return Err(format!("this position takes at most {max_kas} sompi and {max_tokens} base units"));
    }
    let key = keypair(&req.position_secret_key)?;
    if hex(&key.x_only_public_key().0.serialize()) != req.position.state.owner {
        return Err("the secret key does not own the position".into());
    }
    // As the covenant: the pool UTXO's age settles the breaker first; a smaller pool then refills a smaller
    // allowance, so the count is cut down to at most two of its caps.
    // While paused the breaker stands still: the withdrawal claims 0 and settles nothing.
    let elapsed = if s.paused { 0 } else { claim_of(s, req.now_daa, req.pool.utxo.block_daa_score, "withdrawal", least_remove_claim(s))? };
    let (window_ref, window_out, window_credit) = breaker_after_remove(s, req.kas_out, elapsed);
    let next = PoolState {
        kas_reserve: s.kas_reserve - req.kas_out,
        token_reserve: s.token_reserve - req.tokens_out,
        total_shares: s.total_shares - shares,
        window_ref,
        window_credit,
        window_out,
        ..s.clone()
    };
    let pool_id = ctx.pool_covenant.to_string();
    let reserve_next = reserve_state(&pool_id, next.reserve_amount());
    let received = TokenState::plain(protocol::OWNER_P2PK_SCHNORR, &bytes32(&req.receiver, "receiver")?, req.tokens_out);
    let (pool_in, position_in, reserve_in) = (req.pool.utxo.entry()?, req.position.utxo.entry()?, req.reserve.utxo.entry()?);
    let funding = funding_inputs(&req.common.funding)?;
    check_settled_inputs(&req.pool.utxo, &[&req.reserve.utxo, &req.position.utxo].into_iter().chain(req.common.funding.iter().map(|f| &f.utxo)).collect::<Vec<_>>())?;
    let mut entries = vec![pool_in.clone(), position_in.clone(), reserve_in.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let next_states = vec![reserve_next.to_state()?, received.to_state()?];
    let (current, successor) = (s.to_state()?, next.to_state()?);
    let received_state = received.to_state()?;
    let outputs_total = next.value() + req.reserve.utxo.amount + req.token_value;
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let mut context = TxContext::new()
            .actor_input("Pool", current.clone(), EntryCall::new("remove").args(args!(req.kas_out, elapsed, received_state.clone())), req.pool.utxo.outpoint()?, pool_in.clone(), elapsed as u64)
            .actor_input(
                "Position",
                req.position.state.to_state()?,
                EntryCall::new("redeem").args_with(move |tx, i| args!(schnorr_tx_signature(tx, i, &key))),
                req.position.utxo.outpoint()?,
                position_in.clone(),
                0,
            )
            .actor_input("kusdt::KCC20", req.reserve.state.to_state()?, EntryCall::new("transfer").args(args!(next_states.clone(), vec![0x00u8])), req.reserve.utxo.outpoint()?, reserve_in.clone(), 0);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context
            .actor_output("Pool", successor.clone(), CovenantBinding::new(0, ctx.pool_covenant), next.value())
            .actor_output("kusdt::KCC20", next_states[0].clone(), CovenantBinding::new(2, ctx.token_covenant), req.reserve.utxo.amount)
            .actor_output("kusdt::KCC20", received_state.clone(), CovenantBinding::new(2, ctx.token_covenant), req.token_value);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, outputs_total, &make)?;
    let mut built = describe(&tx, fee, mass, Some(ctx.pool_covenant), &[("pool", None, None), ("reserve", Some(reserve_next), None), ("token", Some(received), None)]);
    built.outputs[0].pool = Some(next);
    Ok(built)
}

fn hex(bytes: &[u8]) -> String {
    crate::hex::encode(bytes)
}

// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    pub reserve: Located<TokenState>,
    pub admin_secret_key: String,
    /// x-only key that receives the protocol's tokens.
    pub fees_to: String,
    #[serde(deserialize_with = "crate::model::int::de")]
    pub token_value: u64,
}

pub fn collect(req: &CollectRequest) -> Result<Built, String> {
    let ctx = ids(&req.pool)?;
    check_reserve(&req.pool, &req.reserve, &ctx)?;
    let s = &req.pool.state;
    let admin = keypair(&req.admin_secret_key)?;
    let next = PoolState { protocol_kas: 0, protocol_tokens: 0, ..s.clone() };
    let pool_id = ctx.pool_covenant.to_string();
    let reserve_next = reserve_state(&pool_id, next.reserve_amount());
    let fees = TokenState::plain(protocol::OWNER_P2PK_SCHNORR, &bytes32(&req.fees_to, "feesTo")?, s.protocol_tokens);
    let fees_state = fees.to_state()?;
    let call = move || {
        let fees_state = fees_state.clone();
        EntryCall::new("collect").args_with(move |tx, i| args!(schnorr_tx_signature(tx, i, &admin), fees_state.clone()))
    };
    // `collect` claims no age; its input keeps a sequence of 0.
    swap_tx(&req.common, &req.pool, &req.reserve, &ctx, next, call, None, vec![(reserve_next, req.reserve.utxo.amount), (fees, req.token_value)], 0)
}

// ---------------------------------------------------------------------------

/// Anyone's tick: the pool alone (no kUSDT may move beside it), plus funding
/// for the fee. It settles the breaker with the pool UTXO's age, at least
/// `min_age`, and changes nothing else (SPEC §15).
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TickRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    /// A DAA score the DAG has reached: the breaker's clock.
    #[serde(deserialize_with = "crate::model::int::de")]
    pub now_daa: i64,
}

pub fn tick(req: &TickRequest) -> Result<Built, String> {
    let s = &req.pool.state;
    if s.paused {
        return Err("the pool is paused: its breaker stands still, and a tick is refused".into());
    }
    // pool.ag `tick`: require(total_shares > 0). Between the genesis and the admin's first deposit the pool
    // stays at its genesis outpoint (the launch check looks for it there, and the init is signed for it).
    if s.total_shares <= 0 {
        return Err("the pool has not been opened: before the admin's first deposit there is no breaker to settle, and a tick is refused".into());
    }
    s.check_open()?;
    let elapsed = claim_with(s, req.now_daa, req.pool.utxo.block_daa_score, min_age(s))?;
    let (window_ref, window_out, window_credit) = breaker_settled(s, elapsed);
    let next = PoolState { window_credit, window_ref, window_out, ..s.clone() };
    let pool_in = req.pool.utxo.entry()?;
    let covenant = pool_in.covenant_id.ok_or("the pool UTXO carries no covenant ID")?;
    let funding = funding_inputs(&req.common.funding)?;
    check_settled_inputs(&req.pool.utxo, &req.common.funding.iter().map(|f| &f.utxo).collect::<Vec<_>>())?;
    if funding.is_empty() {
        return Err("a tick spends at least one funding coin for its fee".into());
    }
    let mut entries = vec![pool_in.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let (current, successor) = (s.to_state()?, next.to_state()?);
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        // The pool input's sequence is the relative lock that proves the claimed age.
        let mut context = TxContext::new().actor_input("Pool", current.clone(), EntryCall::new("tick").args(args!(elapsed)), req.pool.utxo.outpoint()?, pool_in.clone(), elapsed as u64);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("Pool", successor.clone(), CovenantBinding::new(0, covenant), pool_in.amount);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, pool_in.amount, &make)?;
    let mut built = describe(&tx, fee, mass, Some(covenant), &[("pool", None, None)]);
    built.outputs[0].pool = Some(next);
    Ok(built)
}

// ---------------------------------------------------------------------------

/// The guardian's pause, the admin's unpause, and the admin's key change: the
/// pool alone (no kUSDT may move beside it), plus funding for the fee.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolKeyRequest {
    #[serde(flatten)]
    pub common: Common,
    pub pool: Located<PoolState>,
    /// The guardian's key (pause) or the admin's (unpause, set-keys).
    pub secret_key: String,
    /// set-keys: the new admin and guardian (each defaults to the current one).
    pub new_admin: Option<String>,
    pub new_guardian: Option<String>,
}

pub fn pause(req: &PoolKeyRequest) -> Result<Built, String> {
    key_tx(req, "pause")
}

pub fn unpause(req: &PoolKeyRequest) -> Result<Built, String> {
    key_tx(req, "unpause")
}

pub fn set_keys(req: &PoolKeyRequest) -> Result<Built, String> {
    key_tx(req, "set_keys")
}

fn key_tx(req: &PoolKeyRequest, entry: &'static str) -> Result<Built, String> {
    let key = keypair(&req.secret_key)?;
    let signer = hex(&key.x_only_public_key().0.serialize());
    let s = &req.pool.state;
    let next = match entry {
        "pause" => {
            if signer != s.guardian {
                return Err("the secret key is not the pool's guardian".into());
            }
            // pool.ag `pause`: require(!paused), as the minter's.
            if s.paused {
                return Err("the pool is already paused: a second pause is refused".into());
            }
            PoolState { paused: true, ..s.clone() }
        }
        "unpause" => {
            if signer != s.admin {
                return Err("the secret key is not the pool's admin".into());
            }
            PoolState { paused: false, ..s.clone() }
        }
        _ => {
            if signer != s.admin {
                return Err("the secret key is not the pool's admin".into());
            }
            let admin = req.new_admin.clone().unwrap_or_else(|| s.admin.clone());
            let guardian = req.new_guardian.clone().unwrap_or_else(|| s.guardian.clone());
            bytes32(&admin, "newAdmin")?;
            bytes32(&guardian, "newGuardian")?;
            PoolState { admin, guardian, ..s.clone() }
        }
    };
    let pool_in = req.pool.utxo.entry()?;
    let covenant = pool_in.covenant_id.ok_or("the pool UTXO carries no covenant ID")?;
    let funding = funding_inputs(&req.common.funding)?;
    check_settled_inputs(&req.pool.utxo, &req.common.funding.iter().map(|f| &f.utxo).collect::<Vec<_>>())?;
    let mut entries = vec![pool_in.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let (current, successor) = (s.to_state()?, next.to_state()?);
    let keys = (bytes32(&next.admin, "admin")?.to_vec(), bytes32(&next.guardian, "guardian")?.to_vec());
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let call = if entry == "set_keys" {
            let (admin, guardian) = keys.clone();
            EntryCall::new("set_keys").args_with(move |tx, i| args!(admin.clone(), guardian.clone(), schnorr_tx_signature(tx, i, &key)))
        } else {
            EntryCall::new(entry).args_with(move |tx, i| args!(schnorr_tx_signature(tx, i, &key)))
        };
        let mut context = TxContext::new().actor_input("Pool", current.clone(), call, req.pool.utxo.outpoint()?, pool_in.clone(), 0);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("Pool", successor.clone(), CovenantBinding::new(0, covenant), pool_in.amount);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, pool_in.amount, &make)?;
    let mut built = describe(&tx, fee, mass, Some(covenant), &[("pool", None, None)]);
    built.outputs[0].pool = Some(next);
    Ok(built)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PositionTransferRequest {
    #[serde(flatten)]
    pub common: Common,
    pub position: Located<PositionState>,
    pub secret_key: String,
    pub new_owner: String,
}

pub fn transfer_position(req: &PositionTransferRequest) -> Result<Built, String> {
    let key = keypair(&req.secret_key)?;
    if hex(&key.x_only_public_key().0.serialize()) != req.position.state.owner {
        return Err("the secret key does not own the position".into());
    }
    let entry = req.position.utxo.entry()?;
    let covenant = entry.covenant_id.ok_or("the position UTXO carries no covenant ID")?;
    let next = PositionState { owner: req.new_owner.clone(), ..req.position.state.clone() };
    let funding = funding_inputs(&req.common.funding)?;
    let mut entries = vec![entry.clone()];
    entries.extend(funding.iter().map(|f| f.entry.clone()));
    let (current, successor) = (req.position.state.to_state()?, next.to_state()?);
    let new_owner = bytes32(&req.new_owner, "newOwner")?.to_vec();
    let builder = pool_builder()?;
    let make = |kas_change: Option<(ScriptPublicKey, u64)>| {
        let new_owner = new_owner.clone();
        let call = EntryCall::new("transfer").args_with(move |tx, i| args!(new_owner.clone(), schnorr_tx_signature(tx, i, &key)));
        let mut context = TxContext::new().actor_input("Position", current.clone(), call, req.position.utxo.outpoint()?, entry.clone(), 0);
        for f in &funding {
            context = context.input(f.outpoint, f.entry.clone(), p2pk_sig_script(f.key), 0);
        }
        context = context.actor_output("Position", successor.clone(), CovenantBinding::new(0, covenant), entry.amount);
        if let Some((script, value)) = kas_change {
            context = context.output(script, None, value);
        }
        Ok(context)
    };
    let (tx, fee, mass) = finish(&builder, &req.common, entries, req.position.utxo.amount, &make)?;
    let mut built = describe(&tx, fee, mass, Some(covenant), &[("position", None, None)]);
    built.outputs[0].position = Some(next);
    Ok(built)
}
