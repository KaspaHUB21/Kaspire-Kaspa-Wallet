//! In-development marketplace covenant. No JNI/WASM entrypoints until validation.
use crate::{CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_txscript::pay_to_address_script;
use serde::{Deserialize, Serialize};
use silverscript_lang::{
    ast::Expr,
    compiler::{compile_contract, CompileOptions, CompiledContract},
};

pub const RESERVE: u64 = 100_000_000;
pub const MIN_PRICE: u64 = 1_000_000; // 0.01 KAS: fee must remain above dust.
pub const MAX_PRICE: u64 = 28_700_000_000 * 100_000_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Terms {
    pub name: String,
    pub seller: String,
    pub price_sompi: u64,
    pub fee_address: String,
}

pub fn amounts(price: u64) -> Result<(u64, u64)> {
    if !(MIN_PRICE..=MAX_PRICE).contains(&price) {
        return Err(CoreError::InvalidRequest(
            "dot.k sale price is outside the supported range".into(),
        ));
    }
    let fee = (u128::from(price) * 21 / 1000) as u64;
    Ok((price - fee, fee))
}

fn pubkey(address: &str) -> Result<Vec<u8>> {
    let address = Address::try_from(address).map_err(|_| CoreError::InvalidAddress)?;
    if address.prefix != Prefix::Mainnet || address.version != Version::PubKey {
        return Err(CoreError::InvalidRequest(
            "dot.k sale requires a Mainnet Schnorr wallet".into(),
        ));
    }
    secp256k1::XOnlyPublicKey::from_slice(&address.payload)
        .map_err(|_| CoreError::InvalidAddress)?;
    Ok(address.payload.to_vec())
}

pub fn deed_script(name: &str, owner_type: u8, owner: &[u8]) -> Result<Vec<u8>> {
    crate::dotk::derive(&crate::dotk::Request {
        name: name.into(),
        owner_type,
        owner: hex::encode(owner),
    })?;
    let deployment: serde_json::Value = serde_json::from_str(include_str!("dotk_mainnet.json"))
        .map_err(|_| CoreError::Serialization)?;
    let mut script = hex::decode(
        deployment["bytecode"]
            .as_str()
            .ok_or(CoreError::Serialization)?,
    )
    .map_err(|_| CoreError::Serialization)?;
    let mut state = vec![1, 2, 32];
    state.extend_from_slice(blake3::hash(name.as_bytes()).as_bytes());
    state.extend_from_slice(&[1, owner_type, 32]);
    state.extend_from_slice(owner);
    state.push(32);
    state.extend_from_slice(name.as_bytes());
    state.resize(103, 0);
    script[1..104].copy_from_slice(&state);
    Ok(script)
}

pub fn compile(terms: &Terms) -> Result<CompiledContract<'static>> {
    let seller = pubkey(&terms.seller)?;
    let fee_address =
        Address::try_from(terms.fee_address.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if fee_address.prefix != Prefix::Mainnet {
        return Err(CoreError::InvalidAddress);
    }
    let spk = pay_to_address_script(&fee_address);
    let mut fee_script = spk.version().to_le_bytes().to_vec();
    fee_script.extend_from_slice(spk.script());
    let (net, fee) = amounts(terms.price_sompi)?;
    let deed = deed_script(&terms.name, 0, &seller)?;
    // Prefix includes the owner-type push opcode; suffix starts with name push.
    let prefix = deed[..37].to_vec();
    let suffix = deed[71..].to_vec();
    compile_contract(
        include_str!("dotk_sale.sil"),
        &[
            Expr::bytes(seller),
            Expr::bytes(fee_script),
            Expr::int(net as i64),
            Expr::int(fee as i64),
            Expr::int(RESERVE as i64),
            Expr::bytes(hex::decode(crate::dotk::REGISTRY).unwrap()),
            Expr::bytes(prefix),
            Expr::bytes(suffix),
        ],
        CompileOptions::default(),
    )
    .map_err(|e| CoreError::Transaction(format!("dot.k sale compile: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn terms() -> Terms {
        Terms {
            name: "kaspire-sale-test".into(),
            seller: crate::derive_address(&format!("private:{}", "01".repeat(32)))
                .unwrap()
                .to_string(),
            fee_address: crate::derive_address(&format!("private:{}", "03".repeat(32)))
                .unwrap()
                .to_string(),
            price_sompi: 10_000_000_000,
        }
    }
    #[test]
    fn exact_integer_fee_split() {
        assert_eq!(
            amounts(10_000_000_000).unwrap(),
            (9_790_000_000, 210_000_000)
        );
        assert_eq!(amounts(1_000_001).unwrap(), (979001, 21000));
        assert!(amounts(0).is_err());
        assert!(amounts(u64::MAX).is_err());
        let (net, fee) = amounts(MAX_PRICE).unwrap();
        assert_eq!(net + fee, MAX_PRICE);
    }
    #[test]
    fn compiles_and_binds_all_sale_terms() {
        let t = terms();
        let original = compile(&t).unwrap().script;
        for changed in [
            Terms {
                name: "other".into(),
                ..t.clone()
            },
            Terms {
                price_sompi: t.price_sompi + 1,
                ..t.clone()
            },
            Terms {
                fee_address: t.seller.clone(),
                ..t.clone()
            },
            Terms {
                seller: t.fee_address.clone(),
                ..t.clone()
            },
        ] {
            assert_ne!(original, compile(&changed).unwrap().script);
        }
    }

    use kaspa_consensus_core::{
        hashing::{
            sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
            sighash_type::SIG_HASH_ALL,
        },
        mass::units::ComputeBudget,
        subnets::SUBNETWORK_ID_NATIVE,
        tx::{
            ComputeCommit, CovenantBinding, PopulatedTransaction, Transaction, TransactionInput,
            TransactionOutpoint, TransactionOutput, UtxoEntry,
        },
        Hash,
    };
    use kaspa_txscript::{
        caches::Cache, covenants::CovenantsContext, pay_to_script_hash_script,
        script_builder::ScriptBuilder, EngineCtx, EngineFlags, TxScriptEngine,
    };

    fn fixture(cancel: bool) -> (Transaction, Vec<UtxoEntry>, CompiledContract<'static>) {
        let t = terms();
        let sale = compile(&t).unwrap();
        let sale_id = Hash::from_bytes([7; 32]);
        let registry: Hash = crate::dotk::REGISTRY.parse().unwrap();
        let secret = format!("private:{}", if cancel { "01" } else { "02" }.repeat(32));
        let recipient = crate::derive_address(&secret).unwrap();
        let old_deed = deed_script(&t.name, 4, &sale_id.as_bytes()).unwrap();
        let next_deed = deed_script(&t.name, 0, &recipient.payload).unwrap();
        let entries = vec![
            UtxoEntry::new(
                100_000_000,
                pay_to_script_hash_script(&old_deed),
                0,
                false,
                Some(registry),
            ),
            UtxoEntry::new(
                RESERVE,
                pay_to_script_hash_script(&sale.script),
                0,
                false,
                Some(sale_id),
            ),
            UtxoEntry::new(
                20_000_000_000,
                pay_to_address_script(&recipient),
                0,
                false,
                None,
            ),
        ];
        let inputs = (0..3)
            .map(|i| {
                TransactionInput::new_with_mass(
                    TransactionOutpoint::new(Hash::from_bytes([10 + i as u8; 32]), 0),
                    vec![],
                    0,
                    ComputeCommit::ComputeBudget(ComputeBudget(100)),
                )
            })
            .collect();
        let seller = Address::try_from(t.seller.as_str()).unwrap();
        let (net, fee) = amounts(t.price_sompi).unwrap();
        let mut outputs = vec![
            TransactionOutput::with_covenant(
                100_000_000,
                pay_to_script_hash_script(&next_deed),
                Some(CovenantBinding::new(0, registry)),
            ),
            TransactionOutput::new(
                if cancel { RESERVE } else { net + RESERVE },
                pay_to_address_script(&seller),
            ),
        ];
        if !cancel {
            outputs.push(TransactionOutput::new(
                fee,
                pay_to_address_script(&Address::try_from(t.fee_address.as_str()).unwrap()),
            ));
        }
        outputs.push(TransactionOutput::new(
            if cancel {
                19_990_000_000
            } else {
                9_990_000_000
            },
            pay_to_address_script(&recipient),
        ));
        let mut tx = Transaction::new(1, inputs, outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        // dot.k ABI: newOwnerType, newOwner, sig[], witness, dispatch tag, redeem.
        tx.inputs[0].signature_script = ScriptBuilder::with_flags(EngineFlags {
            covenants_enabled: true,
            ..Default::default()
        })
        .add_data(&[0])
        .unwrap()
        .add_data(&recipient.payload)
        .unwrap()
        .add_data(&[])
        .unwrap()
        .add_i64(1)
        .unwrap()
        .add_data(&hex::decode("b54f0d61").unwrap())
        .unwrap()
        .add_data(&old_deed)
        .unwrap()
        .drain();
        sign_fixture(&mut tx, &entries, &sale, cancel);
        (tx, entries, sale)
    }

    fn sign_fixture(
        tx: &mut Transaction,
        entries: &[UtxoEntry],
        sale: &CompiledContract<'static>,
        cancel: bool,
    ) {
        sign_fixture_with_hash(tx, entries, sale, cancel, SIG_HASH_ALL);
    }

    fn sign_fixture_with_hash(
        tx: &mut Transaction,
        entries: &[UtxoEntry],
        sale: &CompiledContract<'static>,
        cancel: bool,
        hash_type: kaspa_consensus_core::hashing::sighash_type::SigHashType,
    ) {
        let secret = [if cancel { 1 } else { 2 }; 32];
        let key = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, &secret).unwrap();
        let buyer = key.x_only_public_key().0.serialize();
        for index in [1, 2] {
            let populated = PopulatedTransaction::new(tx, entries.to_vec());
            let hash = calc_schnorr_signature_hash(
                &populated,
                index,
                hash_type,
                &SigHashReusedValuesUnsync::new(),
            );
            let mut signature = key
                .sign_schnorr(secp256k1::Message::from_digest_slice(&hash.as_bytes()).unwrap())
                .as_ref()
                .to_vec();
            signature.push(hash_type.to_u8());
            let script = if index == 1 {
                let args = if cancel {
                    vec![Expr::bytes(signature)]
                } else {
                    vec![Expr::bytes(buyer.to_vec()), Expr::bytes(signature)]
                };
                let mut script = sale
                    .build_sig_script(if cancel { "cancel" } else { "buy" }, args)
                    .unwrap();
                script.extend(
                    ScriptBuilder::with_flags(EngineFlags {
                        covenants_enabled: true,
                        ..Default::default()
                    })
                    .add_data(&sale.script)
                    .unwrap()
                    .drain(),
                );
                script
            } else {
                ScriptBuilder::new().add_data(&signature).unwrap().drain()
            };
            tx.inputs[index].signature_script = script;
        }
        tx.finalize();
    }

    fn execute(tx: &Transaction, entries: &[UtxoEntry]) -> std::result::Result<(), String> {
        let populated = PopulatedTransaction::new(tx, entries.to_vec());
        let covenants = CovenantsContext::from_tx(&populated).map_err(|e| e.to_string())?;
        let cache = Cache::new(100);
        let reused = SigHashReusedValuesUnsync::new();
        for (index, input) in tx.inputs.iter().enumerate() {
            let mut engine = TxScriptEngine::from_transaction_input_with_script_units_limit(
                &populated,
                input,
                index,
                &entries[index],
                EngineCtx::new(&cache)
                    .with_reused(&reused)
                    .with_covenants_ctx(&covenants),
                EngineFlags {
                    covenants_enabled: true,
                    sigop_script_units: kaspa_consensus_core::mass::units::Gram(
                        kaspa_consensus_core::config::params::MAINNET_PARAMS.mass_per_sig_op,
                    )
                    .into(),
                },
                input.compute_commit.allowed_script_units(),
            );
            engine
                .execute()
                .map_err(|e| format!("input {index}: {e}"))?;
        }
        Ok(())
    }

    #[test]
    fn listing_genesis_locks_deed_to_the_derived_sale_id() {
        use kaspa_consensus_core::hashing::covenant_id::covenant_id;
        let t = terms();
        let sale = compile(&t).unwrap();
        let seller = Address::try_from(t.seller.as_str()).unwrap();
        let registry: Hash = crate::dotk::REGISTRY.parse().unwrap();
        let old_deed = deed_script(&t.name, 0, &seller.payload).unwrap();
        let funding = TransactionOutpoint::new(Hash::from_bytes([42; 32]), 0);
        let mut sale_output =
            TransactionOutput::new(RESERVE, pay_to_script_hash_script(&sale.script));
        let sale_id = covenant_id(funding, std::iter::once((1, &sale_output)));
        sale_output.covenant = Some(CovenantBinding::new(1, sale_id));
        let locked = deed_script(&t.name, 4, &sale_id.as_bytes()).unwrap();
        let entries = vec![
            UtxoEntry::new(
                100_000_000,
                pay_to_script_hash_script(&old_deed),
                0,
                false,
                Some(registry),
            ),
            UtxoEntry::new(200_000_000, pay_to_address_script(&seller), 0, false, None),
        ];
        let inputs = [
            TransactionOutpoint::new(Hash::from_bytes([41; 32]), 0),
            funding,
        ]
        .into_iter()
        .map(|outpoint| {
            TransactionInput::new_with_mass(
                outpoint,
                vec![],
                0,
                ComputeCommit::ComputeBudget(ComputeBudget(100)),
            )
        })
        .collect();
        let mut tx = Transaction::new(
            1,
            inputs,
            vec![
                TransactionOutput::with_covenant(
                    100_000_000,
                    pay_to_script_hash_script(&locked),
                    Some(CovenantBinding::new(0, registry)),
                ),
                sale_output,
                TransactionOutput::new(90_000_000, pay_to_address_script(&seller)),
            ],
            0,
            SUBNETWORK_ID_NATIVE,
            0,
            vec![],
        );
        let key = secp256k1::Keypair::from_seckey_slice(secp256k1::SECP256K1, &[1; 32]).unwrap();
        for index in 0..2 {
            let populated = PopulatedTransaction::new(&tx, entries.clone());
            let hash = calc_schnorr_signature_hash(
                &populated,
                index,
                SIG_HASH_ALL,
                &SigHashReusedValuesUnsync::new(),
            );
            let mut sig = key
                .sign_schnorr(secp256k1::Message::from_digest_slice(&hash.as_bytes()).unwrap())
                .as_ref()
                .to_vec();
            sig.push(1);
            let mut builder = ScriptBuilder::with_flags(EngineFlags {
                covenants_enabled: true,
                ..Default::default()
            });
            if index == 0 {
                builder
                    .add_data(&[4])
                    .unwrap()
                    .add_data(&sale_id.as_bytes())
                    .unwrap()
                    .add_data(&sig)
                    .unwrap()
                    .add_i64(0)
                    .unwrap()
                    .add_data(&hex::decode("b54f0d61").unwrap())
                    .unwrap()
                    .add_data(&old_deed)
                    .unwrap();
            } else {
                builder.add_data(&sig).unwrap();
            }
            tx.inputs[index].signature_script = builder.drain();
        }
        tx.finalize();
        execute(&tx, &entries).unwrap();
        // The output hash is independent of the binding, but commits to its
        // index, amount, locking script and the authorizing funding outpoint.
        assert_eq!(
            sale_id,
            covenant_id(funding, std::iter::once((1, &tx.outputs[1])))
        );
        tx.outputs[1].value += 1;
        assert_ne!(
            sale_id,
            covenant_id(funding, std::iter::once((1, &tx.outputs[1])))
        );
        assert!(execute(&tx, &entries).is_err());
    }

    #[test]
    fn rejects_non_all_signatures_and_foreign_covenants() {
        use kaspa_consensus_core::hashing::sighash_type::SigHashType;
        for cancel in [false, true] {
            for hash in [2, 4, 129, 130, 132] {
                let (mut tx, entries, sale) = fixture(cancel);
                sign_fixture_with_hash(
                    &mut tx,
                    &entries,
                    &sale,
                    cancel,
                    SigHashType::from_u8(hash).unwrap(),
                );
                assert!(execute(&tx, &entries).is_err(), "sighash {hash} accepted");
            }
            for index in [0, 1] {
                let (mut tx, mut entries, sale) = fixture(cancel);
                entries[index].covenant_id = Some(Hash::from_bytes([88; 32]));
                sign_fixture(&mut tx, &entries, &sale, cancel);
                assert!(execute(&tx, &entries).is_err(), "foreign covenant accepted");
            }
        }
    }

    #[test]
    fn actual_dotk_and_sale_scripts_accept_atomic_buy_and_cancel() {
        for cancel in [false, true] {
            let (tx, entries, sale) = fixture(cancel);
            eprintln!("sale script bytes: {}", sale.script.len());
            execute(&tx, &entries).unwrap();
            let calculator = kaspa_consensus_core::mass::MassCalculator::new_with_consensus_params(
                &kaspa_consensus_core::config::params::MAINNET_PARAMS,
            );
            let non_contextual = calculator.calc_non_contextual_masses(&tx);
            let contextual = calculator
                .calc_contextual_masses(&PopulatedTransaction::new(&tx, entries))
                .unwrap();
            let mass = kaspa_consensus_core::mass::Mass::new(non_contextual, contextual);
            let params = &kaspa_consensus_core::config::params::MAINNET_PARAMS;
            let effective = mass.normalized_max(&params.mempool_block_mass_cofactors().after());
            eprintln!(
                "cancel={cancel}: effective mass={effective}, limit={}",
                params.mempool_block_mass_limits().after().reference()
            );
            assert!(effective <= params.mempool_block_mass_limits().after().reference());
        }
    }

    #[test]
    fn rejects_underpayment_redirected_fee_and_wrong_deed_even_when_resigned() {
        for mutation in 0..6 {
            let (mut tx, entries, sale) = fixture(false);
            match mutation {
                0 => tx.outputs[1].value -= 1,
                1 => tx.outputs[2].value -= 1,
                2 => tx.outputs[2].script_public_key = tx.outputs[1].script_public_key.clone(),
                3 => tx.outputs[1].script_public_key = tx.outputs[2].script_public_key.clone(),
                4 => tx.outputs[0].value -= 1,
                _ => tx.outputs[0].script_public_key = entries[0].script_public_key.clone(),
            }
            sign_fixture(&mut tx, &entries, &sale, false);
            assert!(
                execute(&tx, &entries).is_err(),
                "mutation {mutation} accepted"
            );
        }
    }
}
