//! Deterministic marketplace transaction builder. Android callers must verify
//! embedded inputs against a trusted live node before authorization/signing.
use crate::{
    dotk_sale::{self, Terms, RESERVE},
    transaction::{parse_utxos, Spendable},
    CoreError, Result,
};
use kaspa_addresses::Address;
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    hashing::{
        covenant_id::covenant_id,
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{ComputeBudget, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, CovenantBinding, PopulatedTransaction, Transaction, TransactionInput,
        TransactionOutpoint, TransactionOutput, UtxoEntry,
    },
    Hash,
};
use kaspa_txscript::{
    pay_to_address_script, pay_to_script_hash_script, script_builder::ScriptBuilder, EngineFlags,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use silverscript_lang::{ast::Expr, compiler::CompiledContract};
use std::collections::HashSet;

const BOND: u64 = 100_000_000;
const DUST: u64 = 10_000;
const MAX_INPUTS: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    List,
    Buy,
    Cancel,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Cell {
    pub transaction_id: String,
    pub index: u32,
    pub value_sompi: u64,
    pub block_daa_score: u64,
    /// Unversioned locking script. Reconstructed independently before use.
    pub script_public_key: String,
    pub covenant_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub action: Action,
    pub sender: String,
    pub terms: Terms,
    pub deed: Cell,
    pub sale: Option<Cell>,
    pub funding_utxos_json: String,
    /// Integer Sompi per fee-mass unit; display the computed total before approval.
    pub fee_rate: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub action: Action,
    pub name: String,
    pub sender: String,
    pub seller: String,
    pub fee_address: String,
    pub price_sompi: u64,
    pub seller_net_sompi: u64,
    pub marketplace_fee_sompi: u64,
    pub sale_reserve_sompi: u64,
    pub deed_bond_sompi: u64,
    pub fee_sompi: u64,
    pub change_sompi: u64,
    pub mass: u64,
    pub storage_mass: u64,
    pub covenant_id: String,
    pub review_hash: String,
    /// Full unsigned transaction + embedded UTXOs, for review and node checks.
    pub transaction_json: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Signed {
    pub transaction_id: String,
    pub wrpc_json: String,
    pub review: Review,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DescribeRequest {
    pub terms: Terms,
    pub sale_id: Option<String>,
}

pub fn describe(r: &DescribeRequest) -> Result<serde_json::Value> {
    let sale = dotk_sale::compile(&r.terms)?;
    let seller =
        Address::try_from(r.terms.seller.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let (owner_type, owner) = match &r.sale_id {
        Some(id) => (4, hex::decode(id).map_err(|_| invalid("invalid sale ID"))?),
        None => (0, seller.payload.to_vec()),
    };
    let deed = crate::dotk::derive(&crate::dotk::Request {
        name: r.terms.name.clone(),
        owner_type,
        owner: hex::encode(owner),
    })?;
    let sale_spk = pay_to_script_hash_script(&sale.script);
    let sale_address =
        kaspa_txscript::extract_script_pub_key_address(&sale_spk, kaspa_addresses::Prefix::Mainnet)
            .map_err(|_| CoreError::InvalidAddress)?;
    Ok(
        serde_json::json!({"deed":deed,"saleAddress":sale_address.to_string(),"saleScriptPublicKey":hex::encode(sale_spk.script()),"saleReserveSompi":RESERVE}),
    )
}

struct Built {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    sale: CompiledContract<'static>,
    old_deed: Vec<u8>,
    owner: Vec<u8>,
    review: Review,
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidRequest(message.into())
}
fn flags() -> EngineFlags {
    EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    }
}

fn cell(input: &Cell, script: &[u8], id: Hash, amount: u64) -> Result<Spendable> {
    if input.covenant_id != id.to_string()
        || input.value_sompi != amount
        || input.script_public_key != hex::encode(script)
    {
        return Err(CoreError::UntrustedUtxo(
            "dot.k sale input conflicts with reconstructed covenant".into(),
        ));
    }
    let txid: Hash = input
        .transaction_id
        .parse()
        .map_err(|_| invalid("invalid sale outpoint"))?;
    Ok(Spendable {
        outpoint: TransactionOutpoint::new(txid, input.index),
        entry: UtxoEntry::new(
            amount,
            kaspa_consensus_core::tx::ScriptPublicKey::new(0, script.into()),
            input.block_daa_score,
            false,
            Some(id),
        ),
    })
}

fn assemble_scripts(
    built: &mut Built,
    action: Action,
    key: Option<&secp256k1::Keypair>,
) -> Result<()> {
    let funding_start = if action == Action::List { 1 } else { 2 };
    for index in 0..built.tx.inputs.len() {
        let signature = if let Some(key) = key {
            let populated = PopulatedTransaction::new(&built.tx, built.entries.clone());
            let hash = calc_schnorr_signature_hash(
                &populated,
                index,
                SIG_HASH_ALL,
                &SigHashReusedValuesUnsync::new(),
            );
            let message = secp256k1::Message::from_digest_slice(&hash.as_bytes())
                .map_err(|_| CoreError::Derivation)?;
            let mut sig = key.sign_schnorr(message).as_ref().to_vec();
            sig.push(1);
            sig
        } else {
            let mut sig = vec![0; 65];
            sig[64] = 1;
            sig
        };
        let script = if index == 0 {
            let mut builder = ScriptBuilder::with_flags(flags());
            builder
                .add_data(&[if action == Action::List { 4 } else { 0 }])
                .and_then(|b| b.add_data(&built.owner))
                .and_then(|b| {
                    b.add_data(if action == Action::List {
                        &signature
                    } else {
                        &[]
                    })
                })
                .and_then(|b| b.add_i64(if action == Action::List { 0 } else { 1 }))
                .and_then(|b| b.add_data(&[0xb5, 0x4f, 0x0d, 0x61]))
                .and_then(|b| b.add_data(&built.old_deed))
                .map_err(|e| CoreError::Transaction(e.to_string()))?;
            builder.drain()
        } else if index < funding_start {
            let args = if action == Action::Buy {
                vec![Expr::bytes(built.owner.clone()), Expr::bytes(signature)]
            } else {
                vec![Expr::bytes(signature)]
            };
            let mut script = built
                .sale
                .build_sig_script(
                    if action == Action::Buy {
                        "buy"
                    } else {
                        "cancel"
                    },
                    args,
                )
                .map_err(|e| CoreError::Transaction(e.to_string()))?;
            script.extend(
                ScriptBuilder::with_flags(flags())
                    .add_data(&built.sale.script)
                    .map_err(|e| CoreError::Transaction(e.to_string()))?
                    .drain(),
            );
            script
        } else {
            ScriptBuilder::new()
                .add_data(&signature)
                .map_err(|e| CoreError::Transaction(e.to_string()))?
                .drain()
        };
        built.tx.inputs[index].signature_script = script;
    }
    built.tx.finalize();
    Ok(())
}

pub fn prepare(request: &Request) -> Result<Review> {
    Ok(build(request)?.review)
}

pub fn sign(secret: &str, request: &Request, approved_review_hash: &str) -> Result<Signed> {
    if crate::derive_address(secret)?.to_string() != request.sender {
        return Err(invalid("key does not control marketplace sender"));
    }
    let mut built = build(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = crate::derive_key(secret)?;
    let pair = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, key.as_ref())
        .map_err(|_| CoreError::Derivation)?;
    assemble_scripts(&mut built, request.action, Some(&pair))?;
    built.tx.set_storage_mass(built.review.storage_mass);
    crate::kcc20::simulate_all(&built.tx, &built.entries)?;
    Ok(Signed {
        transaction_id: built.tx.id().to_string(),
        wrpc_json: crate::kcc20::wrpc_safe_json(&built.tx, &built.entries)?,
        review: built.review,
    })
}

fn build(r: &Request) -> Result<Built> {
    if r.terms.price_sompi < 1_000_000_000 {
        return Err(invalid("marketplace minimum price is 10 KAS"));
    }
    if !(1..=10_000).contains(&r.fee_rate) {
        return Err(invalid("invalid marketplace fee rate"));
    }
    let sender = Address::try_from(r.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if sender.prefix != kaspa_addresses::Prefix::Mainnet
        || sender.version != kaspa_addresses::Version::PubKey
    {
        return Err(invalid("marketplace requires a Mainnet Schnorr wallet"));
    }
    secp256k1::XOnlyPublicKey::from_slice(&sender.payload)
        .map_err(|_| CoreError::InvalidAddress)?;
    if r.action != Action::Buy && r.sender != r.terms.seller {
        return Err(invalid("only the seller may list or cancel"));
    }
    if (r.action == Action::List) != r.sale.is_none() {
        return Err(invalid("unexpected or missing sale cell"));
    }
    let seller =
        Address::try_from(r.terms.seller.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let fee_address =
        Address::try_from(r.terms.fee_address.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    let sale = dotk_sale::compile(&r.terms)?;
    let registry: Hash = crate::dotk::REGISTRY
        .parse()
        .map_err(|_| CoreError::Serialization)?;
    let (net, fee) = dotk_sale::amounts(r.terms.price_sompi)?;
    let mut funding = parse_utxos(&r.funding_utxos_json, &sender)?;
    // Larger UTXOs first: fewer inputs, deterministic outpoint tie-break.
    funding.sort_by(|a, b| {
        b.entry
            .amount
            .cmp(&a.entry.amount)
            .then(a.outpoint.transaction_id.cmp(&b.outpoint.transaction_id))
            .then(a.outpoint.index.cmp(&b.outpoint.index))
    });
    let first = funding.first().ok_or(CoreError::InsufficientFunds)?;
    let mut sale_output = TransactionOutput::new(RESERVE, pay_to_script_hash_script(&sale.script));
    let sale_id: Hash = if let Some(input) = &r.sale {
        input
            .covenant_id
            .parse()
            .map_err(|_| invalid("invalid sale ID"))?
    } else {
        covenant_id(first.outpoint, std::iter::once((1, &sale_output)))
    };
    if sale_id == registry {
        return Err(invalid("sale and deed registry cannot be identical"));
    }
    sale_output.covenant = Some(CovenantBinding::new(1, sale_id));
    let sale_id_bytes = sale_id.as_bytes();
    let old_deed = dotk_sale::deed_script(
        &r.terms.name,
        if r.action == Action::List { 0 } else { 4 },
        if r.action == Action::List {
            &seller.payload
        } else {
            &sale_id_bytes
        },
    )?;
    let mut inputs = vec![cell(
        &r.deed,
        pay_to_script_hash_script(&old_deed).script(),
        registry,
        BOND,
    )?];
    if let Some(input) = &r.sale {
        inputs.push(cell(
            input,
            pay_to_script_hash_script(&sale.script).script(),
            sale_id,
            RESERVE,
        )?);
    }
    let owner = if r.action == Action::List {
        sale_id.as_bytes().to_vec()
    } else {
        sender.payload.to_vec()
    };
    let new_deed = dotk_sale::deed_script(
        &r.terms.name,
        if r.action == Action::List { 4 } else { 0 },
        &owner,
    )?;
    let mut outputs = vec![TransactionOutput::with_covenant(
        BOND,
        pay_to_script_hash_script(&new_deed),
        Some(CovenantBinding::new(0, registry)),
    )];
    match r.action {
        Action::List => outputs.push(sale_output),
        Action::Buy => {
            outputs.push(TransactionOutput::new(
                net + RESERVE,
                pay_to_address_script(&seller),
            ));
            outputs.push(TransactionOutput::new(
                fee,
                pay_to_address_script(&fee_address),
            ));
        }
        Action::Cancel => outputs.push(TransactionOutput::new(
            RESERVE,
            pay_to_address_script(&seller),
        )),
    }
    let required: u64 = if r.action == Action::List {
        RESERVE
    } else if r.action == Action::Buy {
        r.terms.price_sompi
    } else {
        0
    };
    let calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let mut available = 0u64;
    let mut seen: HashSet<_> = inputs.iter().map(|i| i.outpoint).collect();
    if seen.len() != inputs.len() {
        return Err(invalid("duplicate covenant outpoint"));
    }
    let review = Review {
        action: r.action,
        name: format!("{}.k", r.terms.name),
        sender: r.sender.clone(),
        seller: r.terms.seller.clone(),
        fee_address: r.terms.fee_address.clone(),
        price_sompi: r.terms.price_sompi,
        seller_net_sompi: net,
        marketplace_fee_sompi: fee,
        sale_reserve_sompi: RESERVE,
        deed_bond_sompi: BOND,
        fee_sompi: 0,
        change_sompi: 0,
        mass: 0,
        storage_mass: 0,
        covenant_id: sale_id.to_string(),
        review_hash: String::new(),
        transaction_json: String::new(),
    };
    let mut built = Built {
        tx: Transaction::new(1, vec![], vec![], 0, SUBNETWORK_ID_NATIVE, 0, vec![]),
        entries: vec![],
        sale,
        old_deed,
        owner,
        review,
    };
    for coin in funding {
        if inputs.len() >= MAX_INPUTS {
            break;
        }
        if !seen.insert(coin.outpoint) {
            return Err(invalid("duplicate marketplace outpoint"));
        }
        available = available
            .checked_add(coin.entry.amount)
            .ok_or_else(|| invalid("funding sum overflow"))?;
        if available > dotk_sale::MAX_PRICE {
            return Err(invalid("funding exceeds monetary range"));
        }
        inputs.push(coin);
        let Some(excess) = available.checked_sub(required) else {
            continue;
        };
        if excess <= DUST {
            continue;
        }
        let mut candidate = outputs.clone();
        candidate.push(TransactionOutput::new(
            excess,
            pay_to_address_script(&sender),
        ));
        built.tx = Transaction::new(
            1,
            inputs
                .iter()
                .map(|i| {
                    TransactionInput::new_with_mass(
                        i.outpoint,
                        vec![],
                        0,
                        ComputeCommit::ComputeBudget(ComputeBudget(100)),
                    )
                })
                .collect(),
            candidate,
            0,
            SUBNETWORK_ID_NATIVE,
            0,
            vec![],
        );
        built.entries = inputs.iter().map(|i| i.entry.clone()).collect();
        assemble_scripts(&mut built, r.action, None)?;
        let non = calculator.calc_non_contextual_masses(&built.tx);
        let cofactors = MAINNET_PARAMS.mempool_block_mass_cofactors().after();
        let fee_mass = non
            .compute_mass
            .max((non.transient_mass as f64 * cofactors.transient).ceil() as u64);
        let network_fee = fee_mass
            .checked_mul(r.fee_rate)
            .ok_or_else(|| invalid("fee overflow"))?;
        let Some(change) = excess.checked_sub(network_fee) else {
            continue;
        };
        if change < DUST {
            continue;
        }
        built.tx.outputs.last_mut().unwrap().value = change;
        let populated = PopulatedTransaction::new(&built.tx, built.entries.clone());
        let contextual = calculator
            .calc_contextual_masses(&populated)
            .ok_or_else(|| invalid("invalid storage mass"))?;
        let storage = contextual.storage_mass;
        let mass = Mass::new(non, contextual).normalized_max(&cofactors);
        if mass
            > MAINNET_PARAMS
                .mempool_block_mass_limits()
                .after()
                .reference()
        {
            continue;
        }
        built.tx.set_storage_mass(storage);
        built.tx.finalize();
        // A dummy signature is never shown as a completed authorization.
        for input in &mut built.tx.inputs {
            input.signature_script.clear();
        }
        built.tx.finalize();
        built.review.fee_sompi = network_fee;
        built.review.change_sompi = change;
        built.review.mass = mass;
        built.review.storage_mass = storage;
        built.review.transaction_json = crate::kcc20::wrpc_safe_json(&built.tx, &built.entries)?;
        // Domain separation + canonical parsed request + deterministic transaction.
        let mut hasher = Sha256::new();
        hasher.update(b"kaspire-dotk-sale-review-v1\0");
        hasher.update(serde_json::to_vec(r).map_err(|_| CoreError::Serialization)?);
        hasher.update(built.review.transaction_json.as_bytes());
        built.review.review_hash = hex::encode(hasher.finalize());
        return Ok(built);
    }
    Err(invalid(
        "insufficient suitable KAS funding for price, reserve, fee and spendable change",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn secret(byte: u8) -> String {
        format!("private:{}", hex::encode([byte; 32]))
    }
    fn address(byte: u8) -> Address {
        crate::derive_address(&secret(byte)).unwrap()
    }
    fn coin(address: &Address, tx: u8, amount: u64) -> serde_json::Value {
        json!({"address":address.to_string(), "outpoint":{"transactionId":hex::encode([tx;32]),"index":0},
            "utxoEntry":{"amount":amount,"blockDaaScore":100,"isCoinbase":false,
            "scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(address).script())}}})
    }
    fn request() -> Request {
        let sender = address(1);
        let terms = Terms {
            name: "market-test".into(),
            seller: sender.to_string(),
            price_sompi: 10_000_000_000,
            fee_address: address(3).to_string(),
        };
        let deed = dotk_sale::deed_script(&terms.name, 0, &sender.payload).unwrap();
        Request {
            action: Action::List,
            sender: sender.to_string(),
            terms,
            deed: Cell {
                transaction_id: hex::encode([9; 32]),
                index: 0,
                value_sompi: BOND,
                block_daa_score: 10,
                script_public_key: hex::encode(pay_to_script_hash_script(&deed).script()),
                covenant_id: crate::dotk::REGISTRY.into(),
            },
            sale: None,
            funding_utxos_json: json!([coin(&sender, 10, 20_000_000_000)]).to_string(),
            fee_rate: 100,
        }
    }
    fn output_cell(txid: &str, index: usize, tx: &Transaction) -> Cell {
        let output = &tx.outputs[index];
        Cell {
            transaction_id: txid.into(),
            index: index as u32,
            value_sompi: output.value,
            block_daa_score: 100,
            script_public_key: hex::encode(output.script_public_key.script()),
            covenant_id: output.covenant.unwrap().covenant_id.to_string(),
        }
    }
    fn listed() -> Request {
        listed_at(10_000_000_000)
    }
    fn listed_at(price: u64) -> Request {
        let mut r = request();
        r.terms.price_sompi = price;
        let built = build(&r).unwrap();
        let signed = sign(&secret(1), &r, &built.review.review_hash).unwrap();
        r.deed = output_cell(&signed.transaction_id, 0, &built.tx);
        r.sale = Some(output_cell(&signed.transaction_id, 1, &built.tx));
        r.action = Action::Cancel;
        r.funding_utxos_json = json!([coin(&address(1), 11, 20_000_000_000)]).to_string();
        r
    }
    #[test]
    fn purchase_price_storage_boundary() {
        for price in [1_000_000_000, 10_000_000_000] {
            let mut buy = listed_at(price);
            buy.action = Action::Buy;
            buy.sender = address(2).to_string();
            buy.funding_utxos_json = json!([coin(&address(2), 12, 20_000_000_000)]).to_string();
            let review = prepare(&buy).unwrap();
            sign(&secret(2), &buy, &review.review_hash).unwrap();
        }
    }

    #[test]
    fn minimum_price_is_enforced_natively() {
        let mut r = request();
        for price in [0, 1, 100_000_000, 999_999_999] {
            r.terms.price_sompi = price;
            assert!(prepare(&r).is_err());
        }
        r.terms.price_sompi = 1_000_000_000;
        assert!(prepare(&r).is_ok());
    }
    #[test]
    fn complete_list_buy_cancel_sequences_are_signed_and_vm_validated() {
        let r = listed();
        let review = prepare(&r).unwrap();
        assert!(sign(&secret(1), &r, &review.review_hash).is_ok());
        let mut buy = r;
        buy.action = Action::Buy;
        buy.sender = address(2).to_string();
        buy.funding_utxos_json = json!([coin(&address(2), 12, 20_000_000_000)]).to_string();
        let review = prepare(&buy).unwrap();
        let signed = sign(&secret(2), &buy, &review.review_hash).unwrap();
        assert_eq!(signed.review.marketplace_fee_sompi, 210_000_000);
        assert!(signed.wrpc_json.contains("covenant"));
        assert!(!signed.transaction_id.is_empty());
    }
    #[test]
    fn review_is_bound_to_request_and_controlling_key() {
        let r = request();
        let review = prepare(&r).unwrap();
        assert!(sign(&secret(2), &r, &review.review_hash).is_err());
        for kind in 0..4 {
            let mut altered = r.clone();
            match kind {
                0 => altered.terms.price_sompi += 1,
                1 => altered.fee_rate += 1,
                2 => altered.terms.fee_address = address(2).to_string(),
                _ => altered.deed.transaction_id = hex::encode([20; 32]),
            }
            assert!(sign(&secret(1), &altered, &review.review_hash).is_err());
        }
        assert_eq!(review.review_hash, prepare(&r).unwrap().review_hash);
    }
    #[test]
    fn hostile_cells_and_duplicate_inputs_are_rejected() {
        for kind in 0..5 {
            let mut r = request();
            match kind {
                0 => r.deed.covenant_id = hex::encode([2; 32]),
                1 => r.deed.value_sompi += 1,
                2 => r.deed.script_public_key.push_str("00"),
                3 => {
                    r.funding_utxos_json = json!([coin(&address(1), 9, 20_000_000_000)]).to_string()
                }
                _ => {
                    r.funding_utxos_json = json!([
                        coin(&address(1), 10, 20_000_000_000),
                        coin(&address(1), 10, 20_000_000_000)
                    ])
                    .to_string()
                }
            }
            assert!(prepare(&r).is_err(), "accepted mutation {kind}");
        }
        let mut r = listed();
        r.sender = address(2).to_string();
        assert!(prepare(&r).is_err());
    }
    #[test]
    fn fragmented_funding_is_deterministic_and_conserves_value() {
        let mut r = request();
        r.funding_utxos_json = json!((10..20)
            .map(|i| coin(&address(1), i, 50_000_000))
            .collect::<Vec<_>>())
        .to_string();
        let built = build(&r).unwrap();
        assert!(built.entries.len() > 2);
        assert_eq!(
            built.entries.iter().map(|e| e.amount).sum::<u64>(),
            built.tx.outputs.iter().map(|o| o.value).sum::<u64>() + built.review.fee_sompi
        );
        sign(&secret(1), &r, &built.review.review_hash).unwrap();
    }
}
