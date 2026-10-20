//! Offline use of the actual v2.1.0 node validators, with synthetic UTXOs only.
//! No dependency on Kaspire signing/recovery code, RPC client or broadcast path.
#![allow(dead_code, unused_imports)]
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    mass::{ContextualMasses, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        PopulatedTransaction, ScriptPublicKey, Transaction, TransactionInput, TransactionOutpoint,
        TransactionOutput, UtxoEntry,
    },
};
use kaspa_txscript::caches::TxScriptCacheCounters;
use serde_json::{json, Value};
use std::{
    io::{self, Read},
    str::FromStr,
    sync::Arc,
};

mod constants {
    pub use kaspa_consensus_core::config::constants::*;
    pub(crate) use kaspa_consensus_core::constants::*;
}
mod node_validator {
    include!(concat!(env!("OUT_DIR"), "/node_validator/mod.rs"));
}
use node_validator::{tx_validation_in_utxo_context::TxValidationFlags, TransactionValidator};

fn number(v: &Value) -> u64 {
    v.as_u64()
        .or_else(|| v.as_str()?.parse().ok())
        .expect("exact integer fixture")
}
fn script(v: &Value) -> ScriptPublicKey {
    ScriptPublicKey::from_vec(
        number(&v["version"]) as u16,
        hex::decode(v["scriptPublicKey"].as_str().unwrap()).unwrap(),
    )
}
fn parse(case: &Value) -> (Transaction, Vec<UtxoEntry>) {
    let saved: Value = serde_json::from_str(case["saved"]["submitJson"].as_str().unwrap()).unwrap();
    let raw = &saved["transaction"];
    assert_eq!(number(&raw["version"]), 0);
    assert_eq!(
        raw["subnetworkId"],
        "0000000000000000000000000000000000000000"
    );
    let inputs = raw["inputs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            TransactionInput::new(
                TransactionOutpoint::new(
                    FromStr::from_str(i["previousOutpoint"]["transactionId"].as_str().unwrap())
                        .unwrap(),
                    number(&i["previousOutpoint"]["index"]) as u32,
                ),
                hex::decode(i["signatureScript"].as_str().unwrap()).unwrap(),
                number(&i["sequence"]),
                number(&i["sigOpCount"]) as u8,
            )
        })
        .collect();
    let outputs = raw["outputs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| TransactionOutput::new(number(&o["amount"]), script(&o["scriptPublicKey"])))
        .collect();
    let tx = Transaction::new(
        0,
        inputs,
        outputs,
        number(&raw["lockTime"]),
        SUBNETWORK_ID_NATIVE,
        0,
        vec![],
    );
    assert_eq!(
        tx.id().to_string(),
        case["saved"]["transactionId"].as_str().unwrap(),
        "serialized transaction ID must match"
    );
    let rows: Value = serde_json::from_str(case["request"]["utxosJson"].as_str().unwrap()).unwrap();
    let entries = tx
        .inputs
        .iter()
        .map(|i| {
            let row = rows
                .as_array()
                .unwrap()
                .iter()
                .find(|r| {
                    r["outpoint"]["transactionId"] == i.previous_outpoint.transaction_id.to_string()
                        && number(&r["outpoint"]["index"]) == i.previous_outpoint.index as u64
                })
                .unwrap();
            let u = &row["utxoEntry"];
            UtxoEntry::new(
                number(&u["amount"]),
                script(&u["scriptPublicKey"]),
                number(&u["blockDaaScore"]),
                u["isCoinbase"].as_bool().unwrap(),
                None,
            )
        })
        .collect();
    (tx, entries)
}

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let fixture: Value = serde_json::from_str(&input).unwrap();
    let p = &MAINNET_PARAMS;
    let validator = TransactionValidator::new(
        p.max_tx_inputs,
        p.max_tx_outputs,
        p.max_signature_script_len,
        p.max_script_public_key_len,
        p.coinbase_payload_script_public_key_max_len,
        p.coinbase_maturity(),
        p.ghostdag_k,
        Arc::new(TxScriptCacheCounters::default()),
        MassCalculator::new_with_consensus_params(p),
        p.mass_per_sig_op,
    );
    let mut positive = 0;
    let mut negative = 0;
    for (index, case) in fixture["cases"].as_array().unwrap().iter().enumerate() {
        let (tx, entries) = parse(case);
        validator.validate_tx_in_isolation(&tx).unwrap();
        validator
            .validate_tx_in_header_context_with_args(&tx, 1_000_000_000, 1_800_000_000_000)
            .unwrap();
        let populated = PopulatedTransaction::new(&tx, entries.clone());
        // The REST payload does not carry mass. As in mempool processing, first
        // validate and calculate it independently from the full signed witness.
        let fee = validator
            .validate_populated_transaction_and_get_fee(
                &populated,
                1_000_000_000,
                1_000_000_000,
                TxValidationFlags::SkipMassCheck,
                None,
                None,
            )
            .unwrap_or_else(|e| panic!("case {index}: {e}"));
        let contextual = validator
            .mass_calculator
            .calc_contextual_masses(&populated)
            .unwrap();
        let mass = Mass::new(
            validator.mass_calculator.calc_non_contextual_masses(&tx),
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&p.block_mass_cofactors());
        assert_eq!(fee, number(&case["review"]["feeSompi"]));
        assert_eq!(
            mass,
            number(&case["review"]["mass"]),
            "case {index}: mass from serialized signed witness"
        );
        assert!(mass <= 100_000);
        assert!(fee as f64 >= mass as f64 * case["request"]["feeRate"].as_f64().unwrap());
        tx.set_storage_mass(contextual.storage_mass);
        validator
            .validate_populated_transaction_and_get_fee(
                &PopulatedTransaction::new(&tx, entries.clone()),
                1_000_000_000,
                1_000_000_000,
                TxValidationFlags::Full,
                None,
                None,
            )
            .unwrap();
        positive += 1;
        for attack in [
            "signature",
            "sighash",
            "redeem-script",
            "output",
            "input-amount",
            "duplicate-input",
            "mass-commitment",
        ] {
            let mut bad = tx.clone();
            let mut altered = entries.clone();
            match attack {
                "signature" => bad.inputs[0].signature_script[2] ^= 1,
                "sighash" => bad.inputs[0].signature_script[65] = 2,
                "redeem-script" => *bad.inputs[0].signature_script.last_mut().unwrap() ^= 1,
                "output" => bad.outputs[0].value += 1,
                "input-amount" => altered[0].amount += 1,
                "duplicate-input" => {
                    bad.inputs.push(bad.inputs[0].clone());
                    altered.push(altered[0].clone());
                }
                "mass-commitment" => bad.set_storage_mass(contextual.storage_mass + 1),
                _ => unreachable!(),
            }
            bad.finalize();
            let rejected = validator.validate_tx_in_isolation(&bad).is_err()
                || validator
                    .validate_populated_transaction_and_get_fee(
                        &PopulatedTransaction::new(&bad, altered),
                        1_000_000_000,
                        1_000_000_000,
                        if attack == "mass-commitment" {
                            TxValidationFlags::Full
                        } else {
                            TxValidationFlags::SkipMassCheck
                        },
                        None,
                        None,
                    )
                    .is_err();
            assert!(rejected, "case {index}: node validator accepted {attack}");
            negative += 1;
        }
    }
    println!(
        "{}",
        json!({"nodeRelease":"v2.1.0","nodeRevision":env!("KASPIRE_NODE_VALIDATOR_REV"),"validTransactions":positive,"rejectedMutations":negative,"networkAccess":false})
    );
}
