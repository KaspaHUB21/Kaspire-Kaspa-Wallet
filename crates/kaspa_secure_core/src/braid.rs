//! Braid r2c. Network, router identity and economic intent are rebuilt locally.
//! Partner fees include carrier value and use independently proven pool state.
use crate::{
    pskt::{PsktRequest, PsktScriptInput},
    CoreError, Result,
};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    hashing::sighash_type::SigHashType,
    tx::{Transaction, UtxoEntry},
};
use kaspa_txscript::{pay_to_address_script, pay_to_script_hash_script};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

pub(crate) const PIN: &str = "905df466072298313e1cc9e86132ba61f26e2a359f7a7dbd5028fa1963872646";
const EXECUTOR: &str = "fc863156f9ccc914773e1c6d2d0b432e053d265fac52eb456bb7aa749b6eb663";
const FEE_KEY: &str = "aeacb552a8a5f9092ffc4c66c2b5fa794eb81451ab8d1bf6c5b3d845a4622177";
const MAINNET_PIN: &str = "f994470f9bd84d2ca2578a5d8294cc403bb699f19f7e73922c51d04cbb17027d";
const MAINNET_EXECUTOR: &str = "4f6eb864ff5eaf2ab9358d24b425cc41306b3913b061d4cfd54a47ee75f2c4b4";
const MAINNET_FEE_KEY: &str = "0de066137de17b4b8c13761fdbc821c34f9c55579af57c8a9186fee0daed0400";
const PARTNER_KEY: &str = "079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449";
const Z: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const FIELDS: [(&str, bool); 21] = [
    ("recipient", true),
    ("refund", true),
    ("outKind", false),
    ("outCovid", true),
    ("outTpl", true),
    ("outPfl", false),
    ("outSfl", false),
    ("minOut", false),
    ("inKind", false),
    ("inCovid", true),
    ("inTpl", true),
    ("inPfl", false),
    ("inSfl", false),
    ("inAmount", false),
    ("wfeePk", true),
    ("wfee", false),
    ("feeCap", false),
    ("midMin", false),
    ("deadline", false),
    ("intent", true),
    ("tkFloor", false),
];
fn bad(s: &str) -> CoreError {
    CoreError::InvalidRequest(format!("Braid: {s}"))
}
fn bytes(s: &str) -> Result<Vec<u8>> {
    hex::decode(s).map_err(|_| bad("invalid hex"))
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or_else(|| bad("missing string field"))
}
fn number(v: &Value, k: &str) -> Result<u64> {
    let s = text(v, k)?;
    if s.is_empty()
        || s.len() > 19
        || !s.bytes().all(|b| b.is_ascii_digit())
        || (s.len() > 1 && s.starts_with('0'))
    {
        return Err(bad("non-canonical integer"));
    }
    let n = s.parse::<u64>().map_err(|_| bad("invalid integer"))?;
    if n > i64::MAX as u64 {
        return Err(bad("integer exceeds signed range"));
    }
    Ok(n)
}
fn h32(v: &Value, k: &str) -> Result<Vec<u8>> {
    let s = text(v, k)?;
    if s.len() != 64
        || !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(bad("invalid 32-byte identity"));
    }
    bytes(s)
}
fn hash(b: &[u8]) -> Vec<u8> {
    kaspa_hashes::blake2b_simd::Params::new()
        .hash_length(32)
        .hash(b)
        .as_bytes()
        .to_vec()
}
fn keys(v: &Value, allowed: &[&str]) -> Result<()> {
    let o = v.as_object().ok_or_else(|| bad("expected an object"))?;
    if o.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err(bad("unknown transaction or terms field"));
    }
    Ok(())
}
fn state(t: &Value) -> Result<Vec<u8>> {
    keys(t, &FIELDS.map(|(k, _)| k))?;
    let mut out = vec![];
    for (k, b) in FIELDS {
        if b {
            out.push(32);
            out.extend(h32(t, k)?);
        } else {
            out.push(8);
            out.extend(number(t, k)?.to_le_bytes());
        }
    }
    if out.len() != 381 {
        return Err(bad("r2c requires exactly 21 fields"));
    }
    Ok(out)
}
#[derive(Clone, Copy)]
struct Template {
    kind: u64,
    id: &'static str,
    prefix: &'static str,
    length: usize,
    code_hash: &'static str,
}
const REF: Template = Template {
    kind: 1,
    id: "734850b0af0aeef49f009167bf9ddd238fd8c5cdbe214234f97181ac6f5cc498",
    prefix: "6b209703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7",
    length: 3885,
    code_hash: "4f3c7aea48bde5ab8468fe4bbf0b1861758e776972af453a73805fa75d4db508",
};
const KR: Template = Template {
    kind: 1,
    id: "3d689d6273b7631e69f672d5ca744cb266ae997b04974196439858675cc04fe1",
    prefix: "6b20ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b",
    length: 11312,
    code_hash: "b361e9dec692209f6ad5e086f09041cc06476c2642d3c0a3e2321c9341ce81a7",
};
const Q4: Template = Template {
    kind: 1,
    id: "5a93ff33a4791c1c4c2c0da21a24476aa3e06c0f62e3ceaadc491d72efa80b45",
    prefix: "6b20b9be0a8b1c3de1d2ddbddaee1478f8147b9f57ba22c8500b75d542c31221a796",
    length: 4946,
    code_hash: "11356bd4fd3f553e63b46efa5b2d37231658ada3877460b276b6f31ac797c049",
};
const KRON: Template = Template {
    kind: 2,
    id: "2ed46a7edf5b168e67dba56998c58255235bebac436940a85115ca31d5c559f2",
    prefix: "",
    length: 2387,
    code_hash: "7dc133ff0889fd856c8c92d671a06f8851093097ee4b132f86f7d1f6bccc9642",
};
fn template(cid: &str, mainnet: bool) -> Result<Template> {
    if mainnet {
        let pools: Value =
            serde_json::from_str(include_str!("braid_pools.json")).map_err(|_| bad("pool pins"))?;
        return match pools["mainnet"][cid]["venue"].as_str() {
            Some("kr") => Ok(KR),
            Some("kron") => Ok(KRON),
            _ => Err(bad("token is not in the pinned Mainnet integration set")),
        };
    }
    match cid {
        "0282cf6d53023ec08e241919c150d742f54b6f61bac2f1b8f81b7e6343845b9f"
        | "7a1568354b2c70e5919e400856e72f45e3621b674465739c33f0f7ed53fbd9d6"
        | "4a4eff44e065b60ccc9ea8175d818c4e17b2f12d15db50cd570c61f57f1dfb7d" => Ok(Q4),
        "b20f807bed621ca3ea3aaf1f605c6d16d3e3efc766aedefd089db019ceb30526"
        | "a83d58c3a497efe86176939a0ed9d2df13441cb1897c48f89c5851edfad7f61e" => Ok(REF),
        "edca1f844ae0b252d0c11ab98ff850879afad1f04e19aff2754c9eb232b59734" => Ok(KR),
        "86e3e4d1d1d2f41848d82fb732cb0bf3058cf7ee12bb78ba957ce5cc53941bb6"
        | "7ca64292dbdd9672303788da5219f51277a3653c60dfddc1fc7696f842088e8c" => Ok(KRON),
        _ => Err(bad("token is not in the pinned TN10 integration set")),
    }
}
fn side(t: &Value, which: &str, cid: &str, mainnet: bool) -> Result<Option<Template>> {
    let get = |suffix: &str| format!("{which}{suffix}");
    if cid == Z {
        if number(t, &get("Kind"))? != 0
            || text(t, &get("Covid"))? != Z
            || text(t, &get("Tpl"))? != Z
            || number(t, &get("Pfl"))? != 0
            || number(t, &get("Sfl"))? != 0
        {
            return Err(bad("KAS side contains token terms"));
        }
        return Ok(None);
    }
    let p = template(cid, mainnet)?;
    if text(t, &get("Covid"))? != cid
        || number(t, &get("Kind"))? != p.kind
        || text(t, &get("Tpl"))? != p.id
        || number(t, &get("Pfl"))? != p.prefix.len() as u64 / 2
        || number(t, &get("Sfl"))? != p.length as u64
    {
        return Err(bad("token identity or template mismatch"));
    }
    Ok(Some(p))
}
fn note(p: Template, owner: &[u8], amount: u64, p2sh: bool, code: &[u8]) -> Result<Vec<u8>> {
    if code.len() != p.length || hex::encode(hash(code)) != p.code_hash {
        return Err(bad("unknown token program"));
    }
    let mut r = bytes(p.prefix)?;
    if p.kind == 1 {
        r.push(8);
        r.extend(amount.to_le_bytes());
        r.push(32);
        r.extend(owner);
        r.extend([1, if p2sh { 3 } else { 0 }, 1, 0, 32]);
        r.extend([0; 32]);
        r.push(32);
        r.extend([0; 32]);
    } else {
        r.push(32);
        r.extend(owner);
        r.extend([1, if p2sh { 1 } else { 3 }, 8]);
        r.extend(amount.to_le_bytes());
        r.extend([1, 0]);
    }
    r.extend(code);
    Ok(r)
}
fn parse_note(p: Template, r: &[u8], owner: &[u8], p2sh: bool) -> Result<(u64, Vec<u8>)> {
    let pre = bytes(p.prefix)?;
    let n = if p.kind == 1 { 112 } else { 46 };
    if r.len() != pre.len() + n + p.length || !r.starts_with(&pre) {
        return Err(bad("token note length mismatch"));
    }
    let s = &r[pre.len()..pre.len() + n];
    let at = if p.kind == 1 { 1 } else { 36 };
    let amount = u64::from_le_bytes(s[at..at + 8].try_into().unwrap());
    if amount == 0 || amount > i64::MAX as u64 {
        return Err(bad("invalid token note amount"));
    }
    let code = r[pre.len() + n..].to_vec();
    if note(p, owner, amount, p2sh, &code)? != r {
        return Err(bad("token note ownership/policy mismatch"));
    }
    Ok((amount, code))
}

// Values derive from the independently read, hash-checked unspent pool output.
// The application rechecks that exact outpoint immediately before authorization.
fn pool_floor(s: &Value, token: &str, mainnet: bool) -> Result<u64> {
    let proof = &s["valuation"];
    let net = if mainnet { "mainnet" } else { "tn10" };
    let pins: Value =
        serde_json::from_str(include_str!("braid_pools.json")).map_err(|_| bad("pool pins"))?;
    let pin = &pins[net][token];
    if pin.is_null()
        || proof["network"] != net
        || proof["tokenId"] != token
        || proof["poolCovenantId"] != pin["pool"]
        || h32(proof, "transactionId")?.len() != 32
        || proof["index"]
            .as_u64()
            .filter(|n| *n <= u32::MAX as u64)
            .is_none()
    {
        return Err(bad("independent valuation has wrong pool identity"));
    }
    let redeem = bytes(text(proof, "redeem")?)?;
    let kr = pin["venue"] == "kr";
    let start = if kr { 143 } else { 94 };
    if redeem.len()
        != start
            + pin["codeLength"]
                .as_u64()
                .ok_or_else(|| bad("pool length"))? as usize
        || redeem.first() != Some(&107)
        || hex::encode(hash(&redeem[start..])) != pin["codeHash"].as_str().unwrap_or("")
        || text(proof, "scriptPublicKey")? != format!("aa20{}87", hex::encode(hash(&redeem)))
    {
        return Err(bad("independent pool code/script fingerprint differs"));
    }
    let at = |offset: usize| -> Result<u128> {
        let v = u64::from_le_bytes(
            redeem[offset..offset + 8]
                .try_into()
                .map_err(|_| bad("pool integer"))?,
        );
        if v > i64::MAX as u64 {
            return Err(bad("pool integer range"));
        }
        Ok(v as u128)
    };
    let amount = number(s, "amountIn")? as u128;
    let slip = number(s, "slippageBps")? as u128;
    if amount == 0 || !(1..=500).contains(&slip) {
        return Err(bad("invalid valuation quantity/slippage"));
    }
    let value = if kr {
        if (0..8).any(|i| redeem[1 + i * 9] != 8)
            || redeem[73] != 32
            || redeem[106] != 36
            || at(2)? != 1
            || hex::encode(&redeem[74..106]) != token
        {
            return Err(bad("valuation is not this token's graduated pool"));
        }
        let (kas, tok) = (at(65)?, at(56)?);
        if kas == 0 || tok == 0 {
            return Err(bad("empty pool"));
        }
        let gross = kas * amount / (tok + amount);
        let fee = (gross * if mainnet { 100 } else { 30 } / 10000).max(10_000_000);
        gross
            .checked_sub(fee)
            .ok_or_else(|| bad("pool fees exceed sale"))?
    } else {
        if redeem[1] != 8
            || redeem[10] != 8
            || redeem[19] != 32
            || redeem[52] != 8
            || redeem[61] != 32
            || hex::encode(&redeem[20..52]) != token
        {
            return Err(bad("wrong KRON pool layout/token"));
        }
        let (kas, tok, shares) = (at(2)?, at(11)?, at(53)?);
        // Scaled KAS and all computed values stay within the contract range.
        if kas <= 1 || kas > i64::MAX as u128 / 1_000_000 || tok == 0 || shares < 1_000_000 {
            return Err(bad("invalid KRON pool reserves"));
        }
        let retain = |u: u128| {
            if shares == 1_000_000 {
                0
            } else {
                (u * 20 * (shares - 1_000_000) - 1) / (10000 * shares) + 1
            }
        };
        let (mut lo, mut hi) = (0, kas - 1);
        while lo < hi {
            let m = (lo + hi + 1) / 2;
            if kas
                .checked_sub(m + retain(m))
                .is_some_and(|r| r * (tok + amount) >= kas * tok)
            {
                lo = m;
            } else {
                hi = m - 1;
            }
        }
        let gross = lo * 1_000_000;
        let lp = gross * 20 / 10000;
        let fee = (gross / 1000 + lp * 1_000_000 / shares).max(20_000_000)
            + (gross * 70 / 10000).max(20_000_000);
        gross
            .checked_sub(fee)
            .ok_or_else(|| bad("KRON fees exceed sale"))?
    };
    let floor = value * (10000 - slip) / 10000;
    if floor == 0
        || floor > i64::MAX as u128
        || number(proof, "tradeKas")? as u128 != value
        || number(proof, "floor")? as u128 != floor
    {
        return Err(bad("pool valuation differs from local integer math"));
    }
    Ok(floor as u64)
}

fn validate_partner_fee(s: &Value, t: &Value, from: &str, to: &str, mainnet: bool) -> Result<u64> {
    let fee = number(t, "wfee")?;
    if s["feeBps"].is_null() && !mainnet {
        if fee == 0 && text(t, "wfeePk")? == Z && number(t, "tkFloor")? == 0 {
            return Ok(0);
        }
        return Err(bad("legacy fee-free receipt has unexpected fees"));
    }
    if number(s, "feeBps")? != 100
        || fee != number(s, "walletFee")?
        || text(t, "wfeePk")? != if fee == 0 { Z } else { PARTNER_KEY }
    {
        return Err(bad("partner fee rate, amount or beneficiary differs"));
    }
    if fee == 0 {
        if number(t, "tkFloor")? != 0 {
            return Err(bad("floor set without a token fee"));
        }
        return Ok(0);
    }
    if from != Z && to != Z {
        let floor = pool_floor(s, from, mainnet)? as u128;
        let carrier = number(s, "feeCarrier")? as u128;
        let amount = number(s, "amountIn")? as u128;
        if !(10_000_000..=50_000_000).contains(&carrier)
            || number(t, "tkFloor")? as u128 != floor
            || floor / 100 <= carrier
        {
            return Err(bad("token fee carrier/floor differs"));
        }
        let maximum = amount * (floor / 100 - carrier) / floor;
        if fee as u128 != maximum || fee as u128 > amount / 50 {
            return Err(bad(
                "tokens plus carrier differ from independently verified 1% share",
            ));
        }
        return Ok(carrier as u64);
    }
    if number(t, "tkFloor")? != 0 || fee < 10_000_000 {
        return Err(bad("invalid KAS fee/floor"));
    }
    let basis = if from == Z {
        number(s, "payTotal")?
    } else {
        let output = number(s, "quotedAmountOut")?;
        let back = number(s, "kasBack")?;
        let basis = output.checked_sub(back).ok_or_else(|| bad("sale basis"))?;
        let slip = number(s, "slippageBps")?;
        if !(1..=500).contains(&slip)
            || number(t, "minOut")?
                < output.saturating_sub(((basis as u128 * slip as u128 + 9999) / 10000) as u64)
        {
            return Err(bad("sale fee basis not bound to guaranteed payout"));
        }
        basis
    };
    if fee > basis / 100 {
        return Err(bad("partner fee exceeds approved 1%"));
    }
    Ok(0)
}

pub(crate) fn validate(
    r: &PsktRequest,
    tx: &Transaction,
    entries: &[UtxoEntry],
    signatures: &[(usize, SigHashType)],
    scripts: &HashMap<usize, PsktScriptInput>,
) -> Result<()> {
    let sender = Address::try_from(r.sender.as_str()).map_err(|_| bad("invalid wallet"))?;
    let s = r
        .trade_summary
        .as_ref()
        .ok_or_else(|| bad("missing locally approved terms"))?;
    let mainnet = matches!(
        r.profile.as_deref(),
        Some("braid-mainnet-deposit-v1" | "braid-mainnet-reclaim-v1")
    );
    let reclaim = matches!(
        r.profile.as_deref(),
        Some("braid-tn10-reclaim-v1" | "braid-mainnet-reclaim-v1")
    );
    let (pin, executor, fee_key) = if mainnet {
        (MAINNET_PIN, MAINNET_EXECUTOR, MAINNET_FEE_KEY)
    } else {
        (PIN, EXECUTOR, FEE_KEY)
    };
    if !matches!(
        r.profile.as_deref(),
        Some(
            "braid-tn10-deposit-v1"
                | "braid-tn10-reclaim-v1"
                | "braid-mainnet-deposit-v1"
                | "braid-mainnet-reclaim-v1"
        )
    ) || sender.prefix
        != if mainnet {
            Prefix::Mainnet
        } else {
            Prefix::Testnet
        }
        || sender.version != Version::PubKey
        || s["network"] != if mainnet { "mainnet" } else { "testnet-10" }
        || tx.version != 1
        || signatures.iter().any(|(_, h)| h.to_u8() != 1)
        || entries.len() != tx.inputs.len()
        || tx.inputs.len() > 32
        || tx.outputs.len() > 8
    {
        return Err(bad(
            "requires TN10, version 1, exact inputs and SIGHASH_ALL",
        ));
    }
    let raw: Value =
        serde_json::from_str(&r.tx_json_string).map_err(|_| bad("invalid SafeJSON"))?;
    keys(
        &raw,
        &[
            "version",
            "inputs",
            "outputs",
            "lockTime",
            "gas",
            "subnetworkId",
            "storageMass",
            "payload",
        ],
    )?;
    for i in raw["inputs"]
        .as_array()
        .ok_or_else(|| bad("missing inputs"))?
    {
        keys(
            i,
            &[
                "transactionId",
                "index",
                "sequence",
                "sigOpCount",
                "computeBudget",
                "signatureScript",
                "utxo",
            ],
        )?;
        keys(
            &i["utxo"],
            &[
                "address",
                "amount",
                "scriptPublicKey",
                "blockDaaScore",
                "isCoinbase",
                "covenantId",
            ],
        )?;
    }
    for o in raw["outputs"]
        .as_array()
        .ok_or_else(|| bad("missing outputs"))?
    {
        keys(o, &["value", "scriptPublicKey", "covenant"])?;
        if !o["covenant"].is_null() {
            keys(&o["covenant"], &["authorizingInput", "covenantId"])?;
        }
    }
    if tx.inputs.iter().any(|i| i.sequence != 0) {
        return Err(bad("input sequence must be zero"));
    }
    let t = &s["terms"];
    let state = state(t)?;
    let upk = sender.payload.as_slice();
    if h32(t, "recipient")? != upk || h32(t, "refund")? != upk {
        return Err(bad("payout or refund belongs to another wallet"));
    }
    // No staged KRON→KRON execution in this initial profile. A refund must
    // return the original asset; silently returning intermediate KAS is not parity.
    if number(t, "midMin")? != 0 || number(s, "midMin")? != 0 {
        return Err(bad("two-stage routes are not enabled"));
    }
    let from = text(s, "fromId")?;
    let to = text(s, "toId")?;
    if from == to {
        return Err(bad("identical input/output asset"));
    }
    let inp = side(t, "in", from, mainnet)?;
    side(t, "out", to, mainnet)?;
    let carrier = validate_partner_fee(s, t, from, to, mainnet)?;
    let minimum = number(s, "minimumOut")?;
    if minimum == 0 || number(t, "minOut")? < minimum || number(t, "feeCap")? > number(s, "feeCap")?
    {
        return Err(bad("minimum payout or fee cap differs from review"));
    }
    let nonce = h32(s, "nonce")?;
    let reference = text(s, "ref")?;
    if reference.is_empty()
        || reference.len() > 80
        || !reference
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(bad("invalid build reference"));
    }
    if h32(t, "intent")? != hash(&[nonce, reference.as_bytes().to_vec()].concat()) {
        return Err(bad("deposit does not commit to the fresh nonce"));
    }
    let router = &s["router"];
    let prefix = bytes(text(router, "prefix")?)?;
    let suffix = bytes(text(router, "suffix")?)?;
    if prefix != [0x6b]
        || suffix.len() != 6348
        || hex::encode(hash(&[prefix.clone(), suffix.clone()].concat())) != pin
        || text(router, "pin")? != pin
        || text(router, "executor")? != executor
        || text(router, "feePk")? != fee_key
    {
        return Err(bad(
            "router program or keys differ from the pinned r2c release",
        ));
    }
    let redeem = [prefix, state.clone(), suffix].concat();
    let coin = pay_to_script_hash_script(&redeem);
    let sh = hash(&redeem);
    let wallet = pay_to_address_script(&sender);
    let a = number(s, "chainDaa")?;
    let b = number(s, "secondChainDaa")?;
    if a == 0 || b == 0 || a.abs_diff(b) > 600 {
        return Err(bad("two independent chain clocks must agree"));
    }
    let deadline = number(t, "deadline")?;
    let now = a.max(b);
    if deadline >= 500_000_000_000
        || (!reclaim
            && (deadline < now.saturating_add(1800) || deadline > now.saturating_add(12000)))
        || (reclaim && now <= deadline)
    {
        return Err(bad("deadline is outside the permitted chain-time window"));
    }
    let amount = number(s, "amountIn")?;
    if amount == 0 || number(t, "inAmount")? != if inp.is_some() { amount } else { 0 } {
        return Err(bad("input amount mismatch"));
    }
    let selected = signatures.iter().map(|(i, _)| *i).collect::<HashSet<_>>();
    let input_sum = entries
        .iter()
        .try_fold(0u64, |sum, e| sum.checked_add(e.amount))
        .ok_or_else(|| bad("input sum overflow"))?;
    let output_sum = tx
        .outputs
        .iter()
        .try_fold(0u64, |sum, o| sum.checked_add(o.value))
        .ok_or_else(|| bad("output sum overflow"))?;
    let fee = input_sum
        .checked_sub(output_sum)
        .ok_or_else(|| bad("unfunded deposit"))?;
    if fee > if reclaim { 5_000_000 } else { 10_000_000 } {
        return Err(bad("network fee exceeds the local cap"));
    }
    if reclaim {
        let ci = if inp.is_some() { 1 } else { 0 };
        if tx.inputs.len() != ci + 1
            || tx.outputs.len() != ci + 1
            || entries[ci].script_public_key != coin
            || entries[ci].covenant_id.is_some()
            || tx.lock_time != deadline
            || !tx.payload.is_empty()
            || tx.outputs[ci].script_public_key != wallet
            || tx.outputs[ci].covenant.is_some()
            || selected != HashSet::from([ci])
            || scripts.len() != 1
        {
            return Err(bad(
                "reclaim must spend only the saved deposit and return it to this wallet",
            ));
        }
        if tx.inputs[ci].previous_outpoint.transaction_id.to_string()
            != text(s, "depositTransactionId")?
            || tx.inputs[ci].previous_outpoint.index as u64 != number(s, "depositCoinIndex")?
            || entries[ci].amount != number(s, "depositCoinValue")?
        {
            return Err(bad("reclaim differs from the saved deposit"));
        }
        if let Some(p) = inp {
            let nr = bytes(text(s, "depositNoteRedeem")?)?;
            let (n, code) = parse_note(p, &nr, &sh, true)?;
            let output = &tx.outputs[0];
            let binding = output
                .covenant
                .as_ref()
                .ok_or_else(|| bad("recovery note lacks its token binding"))?;
            if n != amount
                || entries[0].script_public_key != pay_to_script_hash_script(&nr)
                || entries[0].covenant_id.map(|h| h.to_string()).as_deref() != Some(from)
                || tx.inputs[0].previous_outpoint.transaction_id.to_string()
                    != text(s, "depositTransactionId")?
                || tx.inputs[0].previous_outpoint.index as u64 != number(s, "depositNoteIndex")?
                || entries[0].amount != number(s, "depositNoteValue")?
                || output.value != entries[0].amount
                || binding.covenant_id.to_string() != from
                || binding.authorizing_input != 0
                || output.script_public_key
                    != pay_to_script_hash_script(&note(p, upk, amount, false, &code)?)
            {
                return Err(bad(
                    "token recovery does not return the exact original note to its owner",
                ));
            }
        }
        let script = scripts
            .get(&ci)
            .ok_or_else(|| bad("missing router reclaim witness"))?;
        if script.script_hex != hex::encode(&redeem) || script.prebuilt_signature_script.is_some() {
            return Err(bad("unexpected reclaim script"));
        }
        let template = serde_json::to_value(&script.signature_script)
            .map_err(|_| bad("invalid reclaim template"))?;
        if template
            != serde_json::json!({"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"35eecca6"}]})
        {
            return Err(bad("reclaim witness selects a different branch"));
        }
        return Ok(());
    }
    if tx.lock_time != 0 {
        return Err(bad("deposit cannot be timelocked"));
    }
    let mut payload = b"BRT1".to_vec();
    payload.extend([4, if mainnet { 0 } else { 1 }]);
    payload.extend(bytes(pin)?);
    payload.extend(bytes(executor)?);
    payload.extend(bytes(fee_key)?);
    payload.extend(&state);
    let check = hash(&payload);
    payload.extend(&check[..4]);
    if tx.payload != payload {
        return Err(bad("recovery payload differs from locally rebuilt BRT1 v4"));
    }
    let ci = number(s, "coinIndex")? as usize;
    let out = tx
        .outputs
        .get(ci)
        .ok_or_else(|| bad("missing router output"))?;
    let wfee = number(t, "wfee")?;
    let token_fee = inp.is_some() && to != Z && wfee > 0;
    let base = if token_fee {
        100_000_000u64
            .checked_add(carrier)
            .ok_or_else(|| bad("carrier overflow"))?
    } else if inp.is_some() {
        100_000_000u64
            .checked_add(wfee)
            .ok_or_else(|| bad("fee overflow"))?
    } else {
        amount
            .checked_add(if to == Z { 10_000_000 } else { 60_000_000 })
            .and_then(|n| n.checked_add(wfee))
            .ok_or_else(|| bad("deposit overflow"))?
    };
    if out.script_public_key != coin
        || out.covenant.is_some()
        || out.value < base
        || out.value >= base.saturating_add(10_000_000)
    {
        return Err(bad(
            "router coin does not match the reviewed terms or value",
        ));
    }
    let mut code = None;
    let mut token_sum = 0u64;
    let mut token_inputs = HashSet::new();
    let mut plain_in = 0u64;
    let mut plain_out = 0u64;
    for (i, e) in entries.iter().enumerate() {
        if e.script_public_key == wallet && e.covenant_id.is_none() {
            if !selected.contains(&i) {
                return Err(bad("unsigned wallet funding input"));
            }
            plain_in = plain_in
                .checked_add(e.amount)
                .ok_or_else(|| bad("funding overflow"))?;
            if scripts.contains_key(&i) {
                return Err(bad("funding input cannot carry a redeem template"));
            }
            continue;
        }
        let p = inp.ok_or_else(|| bad("foreign deposit input"))?;
        let r = bytes(text(&s["inputRedeems"], &i.to_string())?)?;
        let (n, c) = parse_note(p, &r, upk, false)?;
        if e.script_public_key != pay_to_script_hash_script(&r)
            || e.covenant_id.map(|h| h.to_string()).as_deref() != Some(from)
        {
            return Err(bad("token outpoint has a different script or covenant"));
        }
        if code.as_ref().is_some_and(|old: &Vec<u8>| old != &c) {
            return Err(bad("mixed token programs"));
        }
        code = Some(c);
        token_sum = token_sum
            .checked_add(n)
            .ok_or_else(|| bad("token sum overflow"))?;
        token_inputs.insert(i);
        if p.kind == 1 && !selected.contains(&i) {
            return Err(bad("unsigned reference token input"));
        }
        if p.kind == 2 && selected.contains(&i) {
            return Err(bad("KRON presence note is not a Schnorr input"));
        }
        if p.kind == 1 {
            let script = scripts
                .get(&i)
                .ok_or_else(|| bad("missing token witness"))?;
            if script.prebuilt_signature_script.as_deref()
                != Some(hex::encode(&tx.inputs[i].signature_script).as_str())
                || !script.script_hex.is_empty()
            {
                return Err(bad("reference token witness mismatch"));
            }
        }
    }
    if plain_in == 0 {
        return Err(bad("a signed wallet funding input is required"));
    }
    let mut used = HashSet::from([ci]);
    let mut change_script = None;
    if let Some(p) = inp {
        if token_sum < amount {
            return Err(bad("insufficient token input"));
        }
        let c = code.ok_or_else(|| bad("token program missing"))?;
        let ni = number(s, "noteIndex")? as usize;
        let no = tx
            .outputs
            .get(ni)
            .ok_or_else(|| bad("router note missing"))?;
        let nr = note(p, &sh, amount, true, &c)?;
        let binding = no
            .covenant
            .as_ref()
            .ok_or_else(|| bad("router note lacks covenant binding"))?;
        if ni == ci
            || no.script_public_key != pay_to_script_hash_script(&nr)
            || no.value > 50_000_000
            || binding.covenant_id.to_string() != from
            || !token_inputs.contains(&(binding.authorizing_input as usize))
        {
            return Err(bad("router note does not lock the exact sold amount"));
        }
        used.insert(ni);
        if token_sum > amount {
            change_script = Some(pay_to_script_hash_script(&note(
                p,
                upk,
                token_sum - amount,
                false,
                &c,
            )?));
        }
    } else if !scripts.is_empty() || selected.len() != tx.inputs.len() {
        return Err(bad("KAS deposit must sign every plain input"));
    }
    let mut seen_change = false;
    for (i, o) in tx.outputs.iter().enumerate() {
        if used.contains(&i) {
            continue;
        }
        if o.script_public_key == wallet && o.covenant.is_none() {
            plain_out = plain_out
                .checked_add(o.value)
                .ok_or_else(|| bad("change overflow"))?;
            continue;
        }
        if !seen_change
            && change_script.as_ref() == Some(&o.script_public_key)
            && o.value <= 50_000_000
        {
            let binding = o
                .covenant
                .as_ref()
                .ok_or_else(|| bad("token change lacks covenant binding"))?;
            if binding.covenant_id.to_string() != from
                || !token_inputs.contains(&(binding.authorizing_input as usize))
            {
                return Err(bad("token change covenant mismatch"));
            }
            seen_change = true;
            continue;
        }
        return Err(bad("deposit contains an unrelated output"));
    }
    if seen_change != change_script.is_some() {
        return Err(bad("token change is missing"));
    }
    if inp.is_none() && plain_in.checked_sub(plain_out) != Some(number(s, "payTotal")?) {
        return Err(bad("KAS debit differs from the entered total"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independent_mainnet_pool_fee_bound_rejects_forged_values_and_beneficiaries() {
        let proof: Value =
            serde_json::from_str(include_str!("fixtures/braid-mainnet-then-pool.json")).unwrap();
        let from = proof["tokenId"].as_str().unwrap();
        let mut s = serde_json::json!({"amountIn":"10000000","slippageBps":"100","feeBps":"100","valuation":proof,
            "feeCarrier":"20000000"});
        let floor = pool_floor(&s, from, true).unwrap();
        assert_eq!(floor, 297604432362);
        let maximum = 10_000_000u128 * ((floor as u128) / 100 - 20_000_000) / (floor as u128);
        s["walletFee"] = serde_json::json!(maximum.to_string());
        let terms = serde_json::json!({"wfee":maximum.to_string(),"wfeePk":PARTNER_KEY,"tkFloor":floor.to_string()});
        assert_eq!(
            validate_partner_fee(&s, &terms, from, "token-out", true).unwrap(),
            20_000_000
        );
        for field in ["wfee", "wfeePk", "tkFloor"] {
            let mut bad_terms = terms.clone();
            bad_terms[field] = serde_json::json!(if field == "wfeePk" {
                Z.to_string()
            } else {
                "999999999999".to_string()
            });
            assert!(
                validate_partner_fee(&s, &bad_terms, from, "token-out", true).is_err(),
                "{field}"
            );
        }
        for field in [
            "floor",
            "tradeKas",
            "tokenId",
            "poolCovenantId",
            "scriptPublicKey",
            "redeem",
        ] {
            let mut bad_s = s.clone();
            bad_s["valuation"][field] = serde_json::json!("0");
            assert!(pool_floor(&bad_s, from, true).is_err(), "{field}");
        }
        let mut excessive = terms.clone();
        excessive["wfee"] = serde_json::json!((maximum + 1).to_string());
        s["walletFee"] = excessive["wfee"].clone();
        assert!(validate_partner_fee(&s, &excessive, from, "token-out", true).is_err());
    }
    #[test]
    fn mainnet_fee_deposit_and_reclaim_execute_locally() {
        let secret = format!("private:{}", "01".repeat(32));
        let mut address = crate::derive_address(&secret).unwrap();
        address.prefix = Prefix::Mainnet;
        let mut r = fixture();
        r.profile = Some("braid-mainnet-deposit-v1".into());
        r.sender = address.to_string();
        let s = r.trade_summary.as_mut().unwrap();
        s["network"] = serde_json::json!("mainnet");
        s["amountIn"] =
            serde_json::json!((number(s, "amountIn").unwrap() - 30_000_000).to_string());
        s["toId"] =
            serde_json::json!("d8c4356d20712463bbf2da82a5411c3aea18fec024a2b9c014bba1b4524cc8c2");
        s["terms"]["outCovid"] = s["toId"].clone();
        s["terms"]["outTpl"] = serde_json::json!(KR.id);
        s["terms"]["outPfl"] = serde_json::json!("34");
        s["terms"]["outSfl"] = serde_json::json!("11312");
        s["terms"]["wfee"] = serde_json::json!("30000000");
        s["terms"]["wfeePk"] = serde_json::json!(PARTNER_KEY);
        s["feeBps"] = serde_json::json!("100");
        s["walletFee"] = serde_json::json!("30000000");
        let suffix = s["router"]["suffix"]
            .as_str()
            .unwrap()
            .replace(EXECUTOR, MAINNET_EXECUTOR)
            .replace(FEE_KEY, MAINNET_FEE_KEY);
        assert_eq!(
            hex::encode(hash(&[vec![0x6b], bytes(&suffix).unwrap()].concat())),
            MAINNET_PIN
        );
        s["router"]["suffix"] = serde_json::json!(suffix);
        s["router"]["pin"] = serde_json::json!(MAINNET_PIN);
        s["router"]["executor"] = serde_json::json!(MAINNET_EXECUTOR);
        s["router"]["feePk"] = serde_json::json!(MAINNET_FEE_KEY);

        s["terms"]["recipient"] = serde_json::json!(hex::encode(&address.payload));
        s["terms"]["refund"] = s["terms"]["recipient"].clone();
        let st = state(&s["terms"]).unwrap();
        let redeem = [
            vec![0x6b],
            st.clone(),
            bytes(s["router"]["suffix"].as_str().unwrap()).unwrap(),
        ]
        .concat();
        let mut payload = b"BRT1".to_vec();
        payload.extend([4, 0]);
        payload.extend(bytes(MAINNET_PIN).unwrap());
        payload.extend(bytes(MAINNET_EXECUTOR).unwrap());
        payload.extend(bytes(MAINNET_FEE_KEY).unwrap());
        payload.extend(st);
        let check = hash(&payload);
        payload.extend(&check[..4]);
        let mut tx: Value = serde_json::from_str(&r.tx_json_string).unwrap();
        tx["inputs"][0]["transactionId"] = serde_json::json!("11".repeat(32));
        tx["inputs"][0]["utxo"]["address"] = serde_json::json!(r.sender);
        let spk = format!(
            "0000{}",
            hex::encode(pay_to_address_script(&address).script())
        );
        tx["inputs"][0]["utxo"]["scriptPublicKey"] = serde_json::json!(spk);
        tx["outputs"][1]["scriptPublicKey"] = tx["inputs"][0]["utxo"]["scriptPublicKey"].clone();
        tx["outputs"][0]["scriptPublicKey"] = serde_json::json!(format!(
            "0000{}",
            hex::encode(pay_to_script_hash_script(&redeem).script())
        ));
        tx["payload"] = serde_json::json!(hex::encode(payload));
        r.tx_json_string = tx.to_string();
        let review = crate::prepare_pskt(&r).unwrap();
        let signed = crate::sign_pskt(&secret, &r, &review.review_hash).unwrap();
        assert!(signed.wrpc_json.is_some());
        assert_eq!(signed.signed_input_indexes, vec![0]);
        assert!(crate::sign_pskt(&secret, &r, &"00".repeat(32)).is_err());
        let deposited = tx["outputs"][0].clone();
        let mut recovery = r.clone();
        recovery.profile = Some("braid-mainnet-reclaim-v1".into());
        let context = recovery.trade_summary.as_mut().unwrap();
        let deadline = number(&context["terms"], "deadline").unwrap();
        context["chainDaa"] = serde_json::json!((deadline + 1).to_string());
        context["secondChainDaa"] = context["chainDaa"].clone();
        context["depositTransactionId"] = serde_json::json!(signed.transaction_id);
        context["depositCoinIndex"] = serde_json::json!("0");
        context["depositCoinValue"] = deposited["value"].clone();
        let value = deposited["value"].as_str().unwrap().parse::<u64>().unwrap();
        recovery.tx_json_string=serde_json::json!({"version":1,"inputs":[{"transactionId":signed.transaction_id,"index":0,"sequence":"0","sigOpCount":0,"computeBudget":30,"signatureScript":"","utxo":{"amount":value.to_string(),"scriptPublicKey":deposited["scriptPublicKey"],"blockDaaScore":"123","isCoinbase":false,"covenantId":null}}],"outputs":[{"value":(value-5_000_000).to_string(),"scriptPublicKey":spk}],"lockTime":deadline.to_string(),"subnetworkId":"0000000000000000000000000000000000000000","gas":"0","storageMass":"0","payload":""}).to_string();
        recovery.scripts=vec![serde_json::from_value(serde_json::json!({"inputIndex":0,"scriptHex":hex::encode(&redeem),"signType":1,"signatureScript":{"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"35eecca6"}]}})).unwrap()];
        let review = crate::prepare_pskt(&recovery).unwrap();
        let recovered = crate::sign_pskt(&secret, &recovery, &review.review_hash).unwrap();
        assert!(recovered.wrpc_json.is_some());
        recovery.trade_summary.as_mut().unwrap()["depositCoinIndex"] = serde_json::json!("1");
        assert!(crate::prepare_pskt(&recovery).is_err());
    }
    fn push(data: &[u8]) -> Vec<u8> {
        use kaspa_txscript::script_builder::ScriptBuilder;
        ScriptBuilder::new().add_data(data).unwrap().drain()
    }
    #[test]
    fn reference_token_reclaims_execute_against_the_pinned_token_and_router_programs() {
        let secret = format!("private:{}", "01".repeat(32));
        let mut address = crate::derive_address(&secret).unwrap();
        address.prefix = Prefix::Testnet;
        for (cid, p, file) in [
            (
                "b20f807bed621ca3ea3aaf1f605c6d16d3e3efc766aedefd089db019ceb30526",
                REF,
                include_str!("kcc20_standard_template.json"),
            ),
            (
                "edca1f844ae0b252d0c11ab98ff850879afad1f04e19aff2754c9eb232b59734",
                KR,
                include_str!("kcc20_reference_10_template.json"),
            ),
        ] {
            let code: Value = serde_json::from_str(file).unwrap();
            let code = bytes(code["suffix"].as_str().unwrap()).unwrap();
            let mut r = fixture();
            r.sender = address.to_string();
            r.profile = Some("braid-tn10-reclaim-v1".into());
            let s = r.trade_summary.as_mut().unwrap();
            s["fromId"] = serde_json::json!(cid);
            s["toId"] = serde_json::json!(Z);
            s["amountIn"] = serde_json::json!("1000");
            let t = &mut s["terms"];
            t["recipient"] = serde_json::json!(hex::encode(&address.payload));
            t["refund"] = t["recipient"].clone();
            t["inKind"] = serde_json::json!("1");
            t["inCovid"] = serde_json::json!(cid);
            t["inTpl"] = serde_json::json!(p.id);
            t["inPfl"] = serde_json::json!((p.prefix.len() / 2).to_string());
            t["inSfl"] = serde_json::json!(p.length.to_string());
            t["inAmount"] = serde_json::json!("1000");
            for key in ["outKind", "outPfl", "outSfl"] {
                t[key] = serde_json::json!("0");
            }
            for key in ["outCovid", "outTpl"] {
                t[key] = serde_json::json!(Z);
            }
            let deadline = number(t, "deadline").unwrap();
            let router = [
                vec![0x6b],
                state(t).unwrap(),
                bytes(s["router"]["suffix"].as_str().unwrap()).unwrap(),
            ]
            .concat();
            let old = note(p, &hash(&router), 1000, true, &code).unwrap();
            let back = note(p, &address.payload, 1000, false, &code).unwrap();
            let state_only = &back[p.prefix.len() / 2..back.len() - code.len()];
            let witness = [
                state_only.to_vec(),
                push(&[0, 1]),
                push(&[0x79, 0xc7, 0x1c, 0x23]),
                push(&old),
            ]
            .concat();
            let id = "11".repeat(32);
            s["chainDaa"] = serde_json::json!((deadline + 1).to_string());
            s["secondChainDaa"] = s["chainDaa"].clone();
            s["depositTransactionId"] = serde_json::json!(id);
            s["depositCoinIndex"] = serde_json::json!("1");
            s["depositCoinValue"] = serde_json::json!("100000000");
            s["depositNoteIndex"] = serde_json::json!("0");
            s["depositNoteValue"] = serde_json::json!("50000000");
            s["depositNoteRedeem"] = serde_json::json!(hex::encode(&old));
            let packed =
                |b: &[u8]| format!("0000{}", hex::encode(pay_to_script_hash_script(b).script()));
            r.tx_json_string = serde_json::json!({"version":1,"inputs":[
                {"transactionId":id,"index":0,"sequence":"0","computeBudget":150,"sigOpCount":0,"signatureScript":hex::encode(witness),"utxo":{"amount":"50000000","scriptPublicKey":packed(&old),"blockDaaScore":"123","isCoinbase":false,"covenantId":cid}},
                {"transactionId":id,"index":1,"sequence":"0","computeBudget":30,"sigOpCount":0,"signatureScript":"","utxo":{"amount":"100000000","scriptPublicKey":packed(&router),"blockDaaScore":"123","isCoinbase":false,"covenantId":null}}
            ],"outputs":[{"value":"50000000","scriptPublicKey":packed(&back),"covenant":{"authorizingInput":0,"covenantId":cid}},
                {"value":"95000000","scriptPublicKey":format!("0000{}",hex::encode(pay_to_address_script(&address).script()))}],
                "lockTime":deadline.to_string(),"subnetworkId":"0000000000000000000000000000000000000000","gas":"0","storageMass":"0","payload":""}).to_string();
            r.sign_inputs =
                vec![
                    serde_json::from_value(serde_json::json!({"index":1,"sighashType":1})).unwrap(),
                ];
            r.scripts = vec![serde_json::from_value(serde_json::json!({"inputIndex":1,"scriptHex":hex::encode(&router),"signType":1,"signatureScript":{"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"35eecca6"}]}})).unwrap()];
            let review = crate::prepare_pskt(&r).unwrap();
            let result = crate::sign_pskt(&secret, &r, &review.review_hash);
            assert!(result.is_ok(), "{cid}: {result:?}");

            // Full synthetic sell deposit: owned note + signed KAS funding,
            // router note and independent token/KAS change. No chain writes.
            use kaspa_consensus_core::{
                hashing::{
                    sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
                    sighash_type::SIG_HASH_ALL,
                },
                subnets::SUBNETWORK_ID_NATIVE,
                tx::{
                    CovenantBinding, SignableTransaction, TransactionInput, TransactionOutpoint,
                    TransactionOutput,
                },
            };
            use std::str::FromStr;
            let own_note = note(p, &address.payload, 2000, false, &code).unwrap();
            let token_change = note(p, &address.payload, 1000, false, &code).unwrap();
            let mut witness = Vec::new();
            for field in [
                [1000u64.to_le_bytes(), 1000u64.to_le_bytes()].concat(),
                [hash(&router), address.payload.to_vec()].concat(),
                vec![3, 0],
                vec![0, 0],
                vec![0; 64],
                vec![0; 64],
            ] {
                witness.extend(push(&field));
            }
            let slot = witness.len() + 2;
            witness.extend(push(&[0; 66]));
            witness.extend(push(&[0x79, 0xc7, 0x1c, 0x23]));
            witness.extend(push(&own_note));
            let hash_id = kaspa_hashes::Hash::from_str(cid).unwrap();
            let entries = vec![
                UtxoEntry::new(
                    50_000_000,
                    pay_to_script_hash_script(&own_note),
                    123,
                    false,
                    Some(hash_id),
                ),
                UtxoEntry::new(
                    1_000_000_000,
                    pay_to_address_script(&address),
                    123,
                    false,
                    None,
                ),
            ];
            let inputs = vec![
                TransactionInput::new_with_compute_budget(
                    TransactionOutpoint::new(
                        kaspa_hashes::Hash::from_str(&"22".repeat(32)).unwrap(),
                        0,
                    ),
                    witness.clone(),
                    0,
                    150,
                ),
                TransactionInput::new_with_compute_budget(
                    TransactionOutpoint::new(
                        kaspa_hashes::Hash::from_str(&"33".repeat(32)).unwrap(),
                        0,
                    ),
                    vec![],
                    0,
                    11,
                ),
            ];
            let outputs = vec![
                TransactionOutput::new(100_000_000, pay_to_script_hash_script(&router)),
                TransactionOutput::with_covenant(
                    50_000_000,
                    pay_to_script_hash_script(&old),
                    Some(CovenantBinding::new(0, hash_id)),
                ),
                TransactionOutput::with_covenant(
                    50_000_000,
                    pay_to_script_hash_script(&token_change),
                    Some(CovenantBinding::new(0, hash_id)),
                ),
                TransactionOutput::new(849_000_000, pay_to_address_script(&address)),
            ];
            let s = r.trade_summary.as_mut().unwrap();
            let mut payload = b"BRT1".to_vec();
            payload.extend([4, 1]);
            payload.extend(bytes(PIN).unwrap());
            payload.extend(bytes(EXECUTOR).unwrap());
            payload.extend(bytes(FEE_KEY).unwrap());
            payload.extend(state(&s["terms"]).unwrap());
            let check = hash(&payload);
            payload.extend(&check[..4]);
            let tx = Transaction::new(1, inputs, outputs, 0, SUBNETWORK_ID_NATIVE, 0, payload);
            let populated = SignableTransaction::with_entries(tx.clone(), entries.clone());
            let expected = calc_schnorr_signature_hash(
                &populated.as_verifiable(),
                0,
                SIG_HASH_ALL,
                &SigHashReusedValuesUnsync::new(),
            );
            let mut raw: Value =
                serde_json::from_str(&crate::kcc20::wrpc_safe_json(&tx, &entries).unwrap())
                    .unwrap();
            raw.as_object_mut().unwrap().remove("id");
            r.tx_json_string = raw.to_string();
            r.profile = Some("braid-tn10-deposit-v1".into());
            s["chainDaa"] = serde_json::json!((deadline - 6000).to_string());
            s["secondChainDaa"] = s["chainDaa"].clone();
            s["coinIndex"] = serde_json::json!("0");
            s["noteIndex"] = serde_json::json!("1");
            s["inputRedeems"] = serde_json::json!({"0":hex::encode(&own_note)});
            r.sign_inputs = vec![
                serde_json::from_value(serde_json::json!({"index":0,"sighashType":1})).unwrap(),
                serde_json::from_value(serde_json::json!({"index":1,"sighashType":1})).unwrap(),
            ];
            r.scripts=vec![serde_json::from_value(serde_json::json!({"inputIndex":0,"scriptHex":"","signType":1,"prebuiltSignatureScript":hex::encode(&witness),"signatureOffsets":[slot],"expectedSighash":expected.to_string()})).unwrap()];
            let review = crate::prepare_pskt(&r).unwrap();
            let signed = crate::sign_pskt(&secret, &r, &review.review_hash);
            assert!(signed.is_ok(), "{cid} sell deposit: {signed:?}");
        }
    }
    fn fixture() -> PsktRequest {
        serde_json::from_str(include_str!("fixtures/braid-tn10-kas-buy.json")).unwrap()
    }
    #[test]
    fn real_unsigned_build_is_independently_reviewed() {
        let r = fixture();
        let review = crate::prepare_pskt(&r).unwrap();
        assert_eq!(review.input_count, 1);
        assert_eq!(review.output_count, 2);
        assert_eq!(review.fee_sompi, Some(353600));
        assert!(review.final_fee_known);
    }
    #[test]
    fn terms_cannot_redirect_weaken_or_add_fees() {
        for (field, value) in [
            ("recipient", serde_json::json!("11".repeat(32))),
            ("refund", serde_json::json!("11".repeat(32))),
            ("outCovid", serde_json::json!("11".repeat(32))),
            ("outKind", serde_json::json!("2")),
            ("outTpl", serde_json::json!(Z)),
            ("minOut", serde_json::json!("1")),
            ("feeCap", serde_json::json!("1")),
            ("wfee", serde_json::json!("1")),
            ("wfeePk", serde_json::json!("11".repeat(32))),
            ("midMin", serde_json::json!("1")),
            ("tkFloor", serde_json::json!("1")),
            ("inAmount", serde_json::json!("1")),
            ("deadline", serde_json::json!("500000000001")),
            ("intent", serde_json::json!(Z)),
        ] {
            let mut r = fixture();
            r.trade_summary.as_mut().unwrap()["terms"][field] = value;
            assert!(crate::prepare_pskt(&r).is_err(), "accepted {field}");
        }
    }
    #[test]
    fn context_pins_clocks_nonce_and_exact_wallet_debit_are_binding() {
        for (field, value) in [
            ("nonce", serde_json::json!(Z)),
            ("minimumOut", serde_json::json!("900000000")),
            ("payTotal", serde_json::json!("1")),
            ("secondChainDaa", serde_json::json!("1")),
            ("fromId", serde_json::json!("11".repeat(32))),
            ("toId", serde_json::json!("11".repeat(32))),
            ("network", serde_json::json!("mainnet")),
        ] {
            let mut r = fixture();
            r.trade_summary.as_mut().unwrap()[field] = value;
            assert!(crate::prepare_pskt(&r).is_err(), "accepted {field}");
        }
        for field in ["pin", "executor", "feePk"] {
            let mut r = fixture();
            r.trade_summary.as_mut().unwrap()["router"][field] = serde_json::json!(Z);
            assert!(crate::prepare_pskt(&r).is_err());
        }
        let mut r = fixture();
        r.trade_summary.as_mut().unwrap()["router"]["suffix"] =
            serde_json::json!("00".repeat(6348));
        assert!(crate::prepare_pskt(&r).is_err());
    }
    #[test]
    fn transaction_mutations_foreign_outputs_and_non_all_signatures_fail() {
        for mode in 0..8 {
            let mut r = fixture();
            let mut tx: Value = serde_json::from_str(&r.tx_json_string).unwrap();
            match mode {
                0 => tx["outputs"][0]["value"] = serde_json::json!("10000000000"),
                1 => {
                    tx["outputs"][0]["scriptPublicKey"] =
                        tx["outputs"][1]["scriptPublicKey"].clone()
                }
                2 => tx["payload"] = serde_json::json!(""),
                3 => tx["lockTime"] = serde_json::json!("1"),
                4 => tx["inputs"][0]["sequence"] = serde_json::json!("1"),
                5 => tx["unknownSigningAlias"] = serde_json::json!({"address":"attacker"}),
                6 => r.sign_inputs[0].sighash_type = 132,
                _ => tx["inputs"][0]["utxo"]["isCoinbase"] = serde_json::json!(true),
            }
            r.tx_json_string = tx.to_string();
            assert!(crate::prepare_pskt(&r).is_err(), "accepted mutation {mode}");
        }
    }
    #[test]
    fn synthetic_kas_deposit_signs_and_executes_locally() {
        let secret = format!("private:{}", "01".repeat(32));
        let mut address = crate::derive_address(&secret).unwrap();
        address.prefix = Prefix::Testnet;
        let mut r = fixture();
        r.sender = address.to_string();
        let s = r.trade_summary.as_mut().unwrap();
        s["terms"]["recipient"] = serde_json::json!(hex::encode(&address.payload));
        s["terms"]["refund"] = s["terms"]["recipient"].clone();
        let st = state(&s["terms"]).unwrap();
        let redeem = [
            vec![0x6b],
            st.clone(),
            bytes(s["router"]["suffix"].as_str().unwrap()).unwrap(),
        ]
        .concat();
        let mut payload = b"BRT1".to_vec();
        payload.extend([4, 1]);
        payload.extend(bytes(PIN).unwrap());
        payload.extend(bytes(EXECUTOR).unwrap());
        payload.extend(bytes(FEE_KEY).unwrap());
        payload.extend(st);
        let check = hash(&payload);
        payload.extend(&check[..4]);
        let mut tx: Value = serde_json::from_str(&r.tx_json_string).unwrap();
        tx["inputs"][0]["transactionId"] = serde_json::json!("11".repeat(32));
        tx["inputs"][0]["utxo"]["address"] = serde_json::json!(r.sender);
        let spk = format!(
            "0000{}",
            hex::encode(pay_to_address_script(&address).script())
        );
        tx["inputs"][0]["utxo"]["scriptPublicKey"] = serde_json::json!(spk);
        tx["outputs"][1]["scriptPublicKey"] = tx["inputs"][0]["utxo"]["scriptPublicKey"].clone();
        tx["outputs"][0]["scriptPublicKey"] = serde_json::json!(format!(
            "0000{}",
            hex::encode(pay_to_script_hash_script(&redeem).script())
        ));
        tx["payload"] = serde_json::json!(hex::encode(payload));
        r.tx_json_string = tx.to_string();
        let review = crate::prepare_pskt(&r).unwrap();
        let signed = crate::sign_pskt(&secret, &r, &review.review_hash).unwrap();
        assert!(signed.wrpc_json.is_some());
        assert_eq!(signed.signed_input_indexes, vec![0]);
        assert!(crate::sign_pskt(&secret, &r, &"00".repeat(32)).is_err());
        let deposited = tx["outputs"][0].clone();
        let mut recovery = r.clone();
        recovery.profile = Some("braid-tn10-reclaim-v1".into());
        let context = recovery.trade_summary.as_mut().unwrap();
        let deadline = number(&context["terms"], "deadline").unwrap();
        context["chainDaa"] = serde_json::json!((deadline + 1).to_string());
        context["secondChainDaa"] = context["chainDaa"].clone();
        context["depositTransactionId"] = serde_json::json!(signed.transaction_id);
        context["depositCoinIndex"] = serde_json::json!("0");
        context["depositCoinValue"] = deposited["value"].clone();
        let value = deposited["value"].as_str().unwrap().parse::<u64>().unwrap();
        recovery.tx_json_string=serde_json::json!({"version":1,"inputs":[{"transactionId":signed.transaction_id,"index":0,"sequence":"0","sigOpCount":0,"computeBudget":30,"signatureScript":"","utxo":{"amount":value.to_string(),"scriptPublicKey":deposited["scriptPublicKey"],"blockDaaScore":"123","isCoinbase":false,"covenantId":null}}],"outputs":[{"value":(value-5_000_000).to_string(),"scriptPublicKey":spk}],"lockTime":deadline.to_string(),"subnetworkId":"0000000000000000000000000000000000000000","gas":"0","storageMass":"0","payload":""}).to_string();
        recovery.scripts=vec![serde_json::from_value(serde_json::json!({"inputIndex":0,"scriptHex":hex::encode(&redeem),"signType":1,"signatureScript":{"mode":"ordered-args","args":[{"type":"signature","prefixHex":""},{"type":"data","hex":"35eecca6"}]}})).unwrap()];
        let review = crate::prepare_pskt(&recovery).unwrap();
        let recovered = crate::sign_pskt(&secret, &recovery, &review.review_hash).unwrap();
        assert!(recovered.wrpc_json.is_some());
        recovery.trade_summary.as_mut().unwrap()["depositCoinIndex"] = serde_json::json!("1");
        assert!(crate::prepare_pskt(&recovery).is_err());
    }
}
