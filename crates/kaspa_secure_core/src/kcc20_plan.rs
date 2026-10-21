//! One approval binds an entire deterministic standard-KCC20 payment chain.
//! No signing keys or network access are needed to prepare/rebuild the plan.
use crate::kcc20_standard;
use crate::{CoreError, KronTransferRequest, PreparedKronTransfer, Result, SignedPskt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const MAX_CELLS: usize = 65;
const MAX_STEPS: usize = 32;
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidRequest(message.into())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedKcc20Plan {
    pub sender: String,
    pub recipient: String,
    pub covenant_id: String,
    pub ticker: String,
    pub amount: u64,
    pub decimals: u8,
    pub transaction_count: usize,
    pub total_fee_sompi: u64,
    pub steps: Vec<PreparedKronTransfer>,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedKcc20Plan {
    pub review_hash: String,
    pub total_fee_sompi: u64,
    pub transactions: Vec<SignedPskt>,
}

pub fn prepare_kcc20_plan(source: &KronTransferRequest) -> Result<PreparedKcc20Plan> {
    if !kcc20_standard::is_template(&source.template_hash)
        || source.cells.is_empty()
        || source.cells.len() > MAX_CELLS
        || source.amount == 0
        || source.funding_utxos_json.len() > 512 * 1024
    {
        return Err(invalid(
            "Invalid KCC20 payment plan (maximum 65 token cells)",
        ));
    }
    let limit=kcc20_standard::input_limit(&source.template_hash)?;
    let mut seen = HashSet::new();
    let mut total = 0u64;
    // Validate every original cell, including ones spent by later steps.
    kcc20_standard::validate_plan_cells(source)?;
    for cell in &source.cells {
        if cell.token_amount == 0 || !seen.insert(format!("{}:{}", cell.transaction_id, cell.index))
        {
            return Err(invalid("Duplicate or empty KCC20 plan input"));
        }
        total = total
            .checked_add(cell.token_amount)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(|| invalid("KCC20 plan token total overflow"))?;
    }
    if total < source.amount {
        return Err(invalid("Insufficient KCC20 plan balance"));
    }
    let address = kaspa_addresses::Address::try_from(source.sender.as_str())
        .map_err(|_| CoreError::InvalidAddress)?;
    // Canonicalize accepted node JSON variants (string indices / uppercase
    // hashes) before computing spent sets. Otherwise a spent parent funding
    // entry could accidentally remain available to a later plan step.
    let mut funding: Vec<Value> =
        crate::transaction::parse_utxos(&source.funding_utxos_json, &address)?
            .into_iter()
            .map(|u| {
                json!({"address":source.sender,"outpoint":{
            "transactionId":u.outpoint.transaction_id.to_string(),"index":u.outpoint.index},
            "utxoEntry":{"amount":u.entry.amount,"scriptPublicKey":{"version":0,
            "scriptPublicKey":hex::encode(u.entry.script_public_key.script())},
            "blockDaaScore":u.entry.block_daa_score,"isCoinbase":false}})
            })
            .collect();
    let mut cells = source.cells.clone();
    let mut steps = Vec::new();
    let mut total_fee_sompi = 0u64;
    loop {
        if steps.len() >= MAX_STEPS {
            return Err(invalid("KCC20 payment plan exceeds 32 transactions"));
        }
        cells.sort_by(|a, b| {
            b.token_amount
                .cmp(&a.token_amount)
                .then_with(|| a.transaction_id.cmp(&b.transaction_id))
                .then(a.index.cmp(&b.index))
        });
        let mut covered = 0u64;
        let required = cells
            .iter()
            .position(|c| {
                covered += c.token_amount;
                covered >= source.amount
            })
            .ok_or_else(|| invalid("Incomplete KCC20 payment plan"))?
            + 1;
        let compound = required > limit;
        let selected: Vec<_> = cells.drain(..cells.len().min(limit)).collect();
        let selected_total: u64 = selected.iter().map(|c| c.token_amount).sum();
        let request = KronTransferRequest {
            cells: selected.clone(),
            recipient: if compound {
                source.sender.clone()
            } else {
                source.recipient.clone()
            },
            amount: if compound {
                selected_total
            } else {
                source.amount
            },
            funding_utxos_json: serde_json::to_string(&funding)
                .map_err(|_| CoreError::Serialization)?,
            ..source.clone()
        };
        let step = kcc20_standard::prepare(&request)?;
        let review = crate::prepare_pskt(&step.pskt_request)?;
        total_fee_sompi = total_fee_sompi
            .checked_add(step.fee_sompi)
            .ok_or(CoreError::Serialization)?;
        if compound {
            // Remove precisely the spent funding outpoints, then feed the exact
            // parent KAS change into the next transaction. No double spending.
            let spent: HashSet<_> = review.inputs.iter().map(|i| i.outpoint.clone()).collect();
            funding.retain(|row| {
                !spent.contains(&format!(
                    "{}:{}",
                    row["outpoint"]["transactionId"].as_str().unwrap_or(""),
                    row["outpoint"]["index"]
                ))
            });
            let output = review.outputs.last().ok_or(CoreError::Serialization)?;
            funding.push(json!({"address": source.sender, "outpoint": {
                "transactionId": step.transaction_id, "index": output.index}, "utxoEntry": {
                "amount": output.amount_sompi, "scriptPublicKey": {"version": 0,
                "scriptPublicKey": output.script_public_key.strip_prefix("0000").unwrap_or(&output.script_public_key)}, "blockDaaScore": 0, "isCoinbase": false}}));
            cells.push(kcc20_standard::plan_output(
                &selected[0],
                &step.transaction_id,
                selected_total,
                &source.template_hash,
            )?);
        }
        steps.push(step);
        if !compound {
            break;
        }
    }
    // Bind typed source terms AND every fully rebuilt step, not UI metadata.
    let bytes = serde_json::to_vec(&json!({"domain":"kaspire-kcc20-payment-plan-v1",
        "source":source,"steps":steps,"totalFeeSompi":total_fee_sompi}))
    .map_err(|_| CoreError::Serialization)?;
    Ok(PreparedKcc20Plan {
        sender: source.sender.clone(),
        recipient: source.recipient.clone(),
        covenant_id: source.covenant_id.clone(),
        ticker: source.ticker.clone(),
        amount: source.amount,
        decimals: source.decimals,
        transaction_count: steps.len(),
        total_fee_sompi,
        steps,
        review_hash: hex::encode(Sha256::digest(bytes)),
    })
}

pub fn sign_kcc20_plan(
    secret: &str,
    source: &KronTransferRequest,
    approved_hash: &str,
) -> Result<SignedKcc20Plan> {
    let plan = prepare_kcc20_plan(source)?;
    if plan.review_hash != approved_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let mut transactions = Vec::with_capacity(plan.steps.len());
    for step in &plan.steps {
        let review = crate::prepare_pskt(&step.pskt_request)?;
        let signed = crate::sign_pskt(secret, &step.pskt_request, &review.review_hash)?;
        if signed.transaction_id != step.transaction_id {
            return Err(invalid("Signed KCC20 plan dependency changed"));
        }
        transactions.push(signed);
    }
    // Return nothing if any step/VM check fails. Callers persist ALL bytes before broadcast.
    Ok(SignedKcc20Plan {
        review_hash: plan.review_hash,
        total_fee_sompi: plan.total_fee_sompi,
        transactions,
    })
}
