//! Internal experimental vaults; compiler pinned separately from legacy assets.
use crate::kcc20::{simulate_all, submit_json_v1, wrpc_safe_json};
use crate::transaction::{parse_utxos, Spendable};
use crate::{controls_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    constants::TX_VERSION_TOCCATA,
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{units::ComputeBudget, ContextualMasses, Mass, MassCalculator},
    sign::sign_input,
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, CovenantBinding, GenesisCovenantGroup, PopulatedTransaction, Transaction,
        TransactionInput, TransactionOutpoint, TransactionOutput, UtxoEntry,
    },
    Hash,
};
use kaspa_txscript::{
    extract_script_pub_key_address, pay_to_address_script, pay_to_script_hash_script,
    script_builder::ScriptBuilder,
};
use secp256k1::{Keypair, Message, SECP256K1};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
#[cfg(not(target_arch = "wasm32"))]
use silverscript_v1::{
    ast::Expr,
    compiler::{compile_contract, CompileOptions, CompiledContract},
};
#[cfg(target_arch = "wasm32")]
type CompiledContract<'a> = crate::vault_templates::PortableCompiled;

pub const COMPILER_PIN: &str = "silverscript-v1.0.0/3ed973335b59269293564805cc2c58a14595ec03";
pub const PROTOCOL: &str = "kaspire-covenant-vault-v1";
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Terms {
    pub kind: String,
    pub owner: String,
    pub beneficiary: String,
    pub limit_daa: u64,
    pub instance: String,
    pub name: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Cell {
    pub covenant_id: String,
    pub transaction_id: String,
    pub index: u32,
    pub value_sompi: u64,
    pub block_daa_score: u64,
    pub script_public_key: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub action: String,
    pub sender: String,
    pub terms: Terms,
    pub amount_sompi: u64,
    pub current_daa: u64,
    pub fee_rate: f64,
    pub funding_utxos_json: String,
    pub cell: Option<Cell>,
}
struct Built {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    compiled: CompiledContract<'static>,
    review: Value,
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidRequest(s.into())
}
fn address(s: &str) -> Result<Address> {
    let a = Address::try_from(s).map_err(|_| CoreError::InvalidAddress)?;
    if a.prefix != Prefix::Mainnet || a.version != Version::PubKey {
        return Err(invalid("Vault requires a mainnet Schnorr address"));
    }
    secp256k1::XOnlyPublicKey::from_slice(&a.payload).map_err(|_| CoreError::InvalidAddress)?;
    Ok(a)
}
pub fn compile(t: &Terms) -> Result<CompiledContract<'static>> {
    let owner = address(&t.owner)?;
    let instance = hex::decode(&t.instance).map_err(|_| invalid("Invalid vault instance"))?;
    if instance.len() != 32 || instance.iter().all(|v| *v == 0) || t.name.chars().count() > 80 {
        return Err(invalid("Invalid vault name or instance"));
    }
    #[cfg(target_arch = "wasm32")]
    {
        let beneficiary = match t.kind.as_str() {
            "timeLock" if t.beneficiary.is_empty() && t.limit_daa > 0 && t.limit_daa < 500_000_000_000 => vec![],
            "deadManSwitch" if (1200..=3_153_600_000).contains(&t.limit_daa) => address(&t.beneficiary)?.payload.to_vec(),
            _ => return Err(invalid("Invalid vault type or DAA duration")),
        };
        return crate::vault_templates::materialize(&t.kind, &owner.payload, &beneficiary, t.limit_daa as i64, &instance);
    }
    #[cfg(not(target_arch = "wasm32"))]
    let (source, args) = match t.kind.as_str() {
        "timeLock"
            if t.beneficiary.is_empty() && t.limit_daa > 0 && t.limit_daa < 500_000_000_000 =>
        {
            (
                include_str!("vault_time_lock.sil"),
                vec![
                    Expr::bytes(owner.payload.to_vec()),
                    Expr::int(t.limit_daa as i64),
                    Expr::bytes(instance),
                ],
            )
        }
        "deadManSwitch" if (1200..=3_153_600_000).contains(&t.limit_daa) => (
            include_str!("vault_dead_man_switch.sil"),
            vec![
                Expr::bytes(owner.payload.to_vec()),
                Expr::bytes(address(&t.beneficiary)?.payload.to_vec()),
                Expr::int(t.limit_daa as i64),
                Expr::bytes(instance),
            ],
        ),
        _ => return Err(invalid("Invalid vault type or DAA duration")),
    };
    #[cfg(not(target_arch = "wasm32"))]
    { compile_contract(source, &args, CompileOptions::default())
        .map_err(|e| CoreError::Transaction(format!("Official Silverscript vault compile: {e}")))
    }
}
pub fn descriptor(t: &Terms) -> Result<Value> {
    descriptor_compiled(t, &compile(t)?)
}
fn descriptor_compiled(t: &Terms, c: &CompiledContract<'_>) -> Result<Value> {
    let script = pay_to_script_hash_script(&c.bytecode);
    let a = extract_script_pub_key_address(&script, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?;
    Ok(
        json!({"protocol":PROTOCOL,"compiler":COMPILER_PIN,"terms":t,"vaultAddress":a.to_string(),
        "redeemScript":hex::encode(c.bytecode.clone()),"scriptPublicKey":hex::encode(script.script()),"templateHash":hex::encode(c.template_hash())}),
    )
}
pub fn prepare(r: &Request) -> Result<Value> {
    Ok(build(r)?.review)
}
pub fn sign(secret: &str, r: &Request, approved: &str) -> Result<Value> {
    if !controls_address(secret, &r.sender)? {
        return Err(invalid(
            "Signing wallet does not control the vault action address",
        ));
    }
    let mut b = build(r)?;
    if b.review["reviewHash"].as_str() != Some(approved) {
        return Err(CoreError::ReviewMismatch);
    }
    sign_built(secret, r, &mut b)?;
    Ok(
        json!({"transactionId":b.tx.id().to_string(),"record":b.review["record"],"feeSompi":b.review["feeSompi"],
        "submitJson":submit_json_v1(&b.tx)?,"wrpcJson":wrpc_safe_json(&b.tx,&b.entries)?,"reviewHash":approved}),
    )
}
fn sign_built(secret: &str, r: &Request, b: &mut Built) -> Result<()> {
    let key = derive_key(secret)?;
    for i in 0..b.tx.inputs.len() {
        if i == 0 && r.action != "create" {
            let hash = calc_schnorr_signature_hash(
                &PopulatedTransaction::new(&b.tx, b.entries.clone()),
                0,
                SIG_HASH_ALL,
                &SigHashReusedValuesUnsync::new(),
            );
            let msg = Message::from_digest_slice(&hash.as_bytes())
                .map_err(|_| CoreError::Serialization)?;
            let mut sig = SECP256K1
                .sign_schnorr_no_aux_rand(
                    &msg,
                    &Keypair::from_seckey_slice(SECP256K1, &*key)
                        .map_err(|_| CoreError::InvalidAddress)?,
                )
                .as_ref()
                .to_vec();
            sig.push(SIG_HASH_ALL.to_u8());
            let tag = b
                .compiled
                .dispatch_tags
                .get(&r.action)
                .ok_or_else(|| invalid("Unknown vault action"))?;
            b.tx.inputs[0].signature_script = ScriptBuilder::new()
                .add_data(&sig)
                .and_then(|s| s.add_data(tag))
                .and_then(|s| s.add_data(&b.compiled.bytecode))
                .map_err(|e| CoreError::Transaction(e.to_string()))?
                .drain();
        } else {
            b.tx.inputs[i].signature_script = sign_input(
                &PopulatedTransaction::new(&b.tx, b.entries.clone()),
                i,
                &*key,
                SIG_HASH_ALL,
            );
        }
    }
    b.tx.finalize();
    simulate_all(&b.tx, &b.entries)
}
/// Bypass the local review policy in tests so covenant consensus checks are
/// exercised independently, with VALID signatures over malicious outputs.
#[cfg(test)]
pub(crate) fn rejects_mutated_transaction(
    secret: &str,
    r: &Request,
    mutate: impl FnOnce(&mut Transaction),
) -> bool {
    let mut b = build(r).expect("valid test fixture");
    mutate(&mut b.tx);
    sign_built(secret, r, &mut b).is_err()
}
fn build(r: &Request) -> Result<Built> {
    if !r.fee_rate.is_finite()
        || !(100.0..=10_000.0).contains(&r.fee_rate)
        || r.current_daa == 0
        || r.current_daa >= 500_000_000_000
    {
        return Err(invalid("Invalid vault fee rate or node DAA score"));
    }
    let c = compile(&r.terms)?;
    let description = descriptor_compiled(&r.terms, &c)?;
    let sender = address(&r.sender)?;
    let vault_spk = pay_to_script_hash_script(&c.bytecode);
    let heartbeat = r.action == "heartbeat";
    let create = r.action == "create";
    match r.action.as_str() {
        "create" | "heartbeat" if r.sender == r.terms.owner => {}
        "release"
            if r.terms.kind == "timeLock"
                && r.sender == r.terms.owner
                && r.current_daa > r.terms.limit_daa => {}
        "claim" if r.terms.kind == "deadManSwitch" && r.sender == r.terms.beneficiary => {}
        _ => {
            return Err(invalid(
                "This wallet/action cannot open this vault, or the time lock has not matured",
            ))
        }
    }
    if heartbeat && r.terms.kind != "deadManSwitch" {
        return Err(invalid("Only Dead Man's Switch vaults support pulses"));
    }
    let mut vault = None;
    if create {
        if r.cell.is_some()
            || !(100_000_000..=2_870_000_000_000_000_000).contains(&r.amount_sompi)
            || (r.terms.kind == "timeLock" && r.terms.limit_daa <= r.current_daa)
        {
            return Err(invalid("Invalid vault deposit or unlock DAA"));
        }
    } else {
        let cell = r
            .cell
            .as_ref()
            .ok_or_else(|| invalid("Missing vault output"))?;
        if cell.value_sompi != r.amount_sompi
            || cell.block_daa_score == 0
            || cell.script_public_key != hex::encode(vault_spk.script())
        {
            return Err(invalid(
                "Vault output differs from locally compiled covenant",
            ));
        }
        if r.action == "claim"
            && r.current_daa <= cell.block_daa_score.saturating_add(r.terms.limit_daa)
        {
            return Err(invalid("Beneficiary timer has not matured"));
        }
        let id: Hash = cell
            .covenant_id
            .parse()
            .map_err(|_| invalid("Invalid covenant ID"))?;
        if id == Hash::from_bytes([0; 32]) {
            return Err(invalid("Vault has no covenant identity"));
        }
        vault = Some((
            TransactionOutpoint::new(
                cell.transaction_id
                    .parse()
                    .map_err(|_| invalid("Invalid vault outpoint"))?,
                cell.index,
            ),
            UtxoEntry::new(
                cell.value_sompi,
                vault_spk.clone(),
                cell.block_daa_score,
                false,
                Some(id),
            ),
        ));
    }
    let funding = if create || heartbeat {
        parse_utxos(&r.funding_utxos_json, &sender)?
    } else {
        vec![]
    };
    let candidates: Vec<Option<Spendable>> = if create || heartbeat {
        funding.into_iter().map(Some).collect()
    } else {
        vec![None]
    };
    let calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    for fund in candidates {
        let mut fee = 0u64;
        for _ in 0..12 {
            let mut entries = vec![];
            let mut inputs = vec![];
            let mut outputs = vec![];
            if let Some((point, entry)) = &vault {
                inputs.push(TransactionInput::new_with_mass(
                    *point,
                    vec![],
                    if r.action == "claim" {
                        r.terms.limit_daa
                    } else {
                        0
                    },
                    ComputeCommit::ComputeBudget(ComputeBudget(40)),
                ));
                entries.push(entry.clone());
            }
            if let Some(f) = &fund {
                if vault.as_ref().is_some_and(|v| v.0 == f.outpoint) {
                    break;
                }
                inputs.push(TransactionInput::new_with_mass(
                    f.outpoint,
                    vec![],
                    0,
                    ComputeCommit::ComputeBudget(ComputeBudget(10)),
                ));
                entries.push(f.entry.clone());
                // Spendable beneficiary discovery notice, not a protocol fee.
                // Tiny dust outputs violate Toccata storage-mass limits.
                let notice = if create && r.terms.kind == "deadManSwitch" {
                    10_000_000
                } else {
                    0
                };
                let spend = if create { r.amount_sompi } else { 0 };
                let Some(change) = f
                    .entry
                    .amount
                    .checked_sub(spend)
                    .and_then(|a| a.checked_sub(notice))
                    .and_then(|a| a.checked_sub(fee))
                else {
                    break;
                };
                if change < 10_000 {
                    break;
                }
                outputs.push(TransactionOutput::new(r.amount_sompi, vault_spk.clone()));
                outputs.push(TransactionOutput::new(
                    change,
                    pay_to_address_script(&sender),
                ));
                if notice > 0 {
                    outputs.push(TransactionOutput::new(
                        notice,
                        pay_to_address_script(&address(&r.terms.beneficiary)?),
                    ));
                }
            } else {
                let Some(value) = r.amount_sompi.checked_sub(fee) else {
                    break;
                };
                if value < 10_000 {
                    break;
                }
                outputs.push(TransactionOutput::new(
                    value,
                    pay_to_address_script(&sender),
                ));
            }
            if heartbeat {
                outputs[0].covenant = Some(CovenantBinding {
                    authorizing_input: 0,
                    covenant_id: entries[0].covenant_id.unwrap(),
                });
            }
            let payload=serde_json::to_vec(&json!({"p":PROTOCOL,"action":r.action,"terms":r.terms,"amountSompi":r.amount_sompi,"vaultAddress":description["vaultAddress"]})).map_err(|_|CoreError::Serialization)?;
            let mut tx = Transaction::new(
                TX_VERSION_TOCCATA,
                inputs,
                outputs,
                if r.action == "release" {
                    r.terms.limit_daa
                } else {
                    0
                },
                SUBNETWORK_ID_NATIVE,
                0,
                payload,
            );
            if create {
                tx.populate_genesis_covenants(&[GenesisCovenantGroup::new(0, vec![0])])
                    .map_err(|e| CoreError::Transaction(e.to_string()))?;
            }
            // Conservative size/compute estimate includes the final covenant witness.
            for i in 0..tx.inputs.len() {
                tx.inputs[i].signature_script = if i == 0 && !create {
                    let tag = c
                        .dispatch_tags
                        .get(&r.action)
                        .ok_or_else(|| invalid("Unknown vault entry"))?;
                    ScriptBuilder::new()
                        .add_data(&[0; 65])
                        .and_then(|s| s.add_data(tag))
                        .and_then(|s| s.add_data(&c.bytecode))
                        .map_err(|e| CoreError::Transaction(e.to_string()))?
                        .drain()
                } else {
                    vec![0; 66]
                };
            }
            let p = PopulatedTransaction::new(&tx, entries.clone());
            let nc = calculator.calc_non_contextual_masses(&tx);
            let ctx = calculator
                .calc_contextual_masses(&p)
                .ok_or_else(|| invalid("Cannot calculate vault storage mass"))?;
            let factors = MAINNET_PARAMS.block_mass_cofactors();
            let mass =
                Mass::new(nc, ContextualMasses::new(ctx.storage_mass)).normalized_max(&factors);
            if mass > MAINNET_PARAMS.block_mass_limits.reference()
                || ctx.storage_mass > MAINNET_PARAMS.block_mass_limits.storage * 85 / 100
            {
                break;
            }
            let required = (r.fee_rate
                * (nc
                    .compute_mass
                    .max((nc.transient_mass as f64 * factors.transient).ceil() as u64))
                    as f64)
                .ceil() as u64;
            if required > 15_000_000 {
                return Err(invalid("Vault network fee exceeds 0.15 KAS safety limit"));
            }
            if fee < required {
                fee = required;
                continue;
            }
            for input in &mut tx.inputs {
                input.signature_script.clear();
            }
            tx.set_storage_mass(ctx.storage_mass);
            tx.finalize();
            let cid = if create {
                tx.outputs[0].covenant.unwrap().covenant_id.to_string()
            } else {
                r.cell.as_ref().unwrap().covenant_id.clone()
            };
            let mut record = description.clone();
            record["covenantId"] = json!(cid);
            record["amountSompi"] = json!(r.amount_sompi);
            record["transactionId"] = json!(tx.id().to_string());
            record["index"] = json!(0);
            record["status"] = json!(if create || heartbeat {
                "pending"
            } else {
                "opening"
            });
            let mut review = json!({"profile":PROTOCOL,"action":r.action,"sender":r.sender,"terms":r.terms,"record":record,"covenantId":cid,
                "amountSompi":r.amount_sompi,"feeSompi":fee,"mass":mass,"transactionId":tx.id().to_string(),"currentDaa":r.current_daa,
                "beneficiaryNoticeSompi":if create&&r.terms.kind=="deadManSwitch" {10_000_000u64}else{0u64},
                "recipient":if create||heartbeat {record["vaultAddress"].clone()}else{json!(r.sender)}});
            // Bind outpoints, DAA, terms, outputs and funding entries to the approved review.
            review["reviewHash"] = json!(hex::encode(Sha256::digest(
                serde_json::to_vec(&(r, &review)).map_err(|_| CoreError::Serialization)?
            )));
            return Ok(Built {
                tx,
                entries,
                compiled: c,
                review,
            });
        }
    }
    Err(invalid("No suitable spendable output covers this vault and its fee. Compound KAS UTXOs first if necessary"))
}
