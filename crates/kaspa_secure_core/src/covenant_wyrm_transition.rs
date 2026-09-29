use crate::covenant_wyrm::{compile_state, template_hash, WyrmState};
use crate::kcc20::{simulate_all, submit_json_v1, wrpc_safe_json};
use crate::transaction::parse_utxos;
use crate::{controls_address, derive_key, CoreError, Result};
use kaspa_addresses::{Address, Prefix, Version as AddressVersion};
use kaspa_consensus_core::{
    config::params::MAINNET_PARAMS,
    constants::TX_VERSION_TOCCATA,
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    mass::{units::ComputeBudget, ContextualMasses, Mass, MassCalculator},
    subnets::SUBNETWORK_ID_NATIVE,
    tx::{
        ComputeCommit, CovenantBinding, PopulatedTransaction, Transaction, TransactionId,
        TransactionInput, TransactionOutpoint, TransactionOutput, UtxoEntry,
    },
    Hash,
};
use kaspa_txscript::{
    extract_script_pub_key_address, pay_to_address_script, pay_to_script_hash_script,
    script_builder::ScriptBuilder, EngineFlags,
};
use secp256k1::{Keypair, Message, SECP256K1};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use silverscript_lang::{
    ast::Expr,
    compiler::{struct_object, CompiledContract, CovenantDeclCallOptions},
};
use std::str::FromStr;

const WYRM_COMPUTE_BUDGET: u16 = 24;
const FUNDING_COMPUTE_BUDGET: u16 = 10;
const DUST_SOMPI: u64 = 10_000;
const STORAGE_LIMIT_PERCENT: u64 = 85;
const TWELVE_HOURS_DAA: u64 = 432_000;
const DAY_DAA: u64 = 864_000;
const THREE_DAYS_DAA: u64 = 2_592_000;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum WyrmAction {
    Incubate,
    Warm,
    Hatch,
    Feed,
    Transfer,
    Grow,
    Die,
    Name,
    Sleep,
    Wake,
    SpecialFeed,
}

impl WyrmAction {
    fn code(self) -> u8 {
        match self {
            Self::Incubate => 1,
            Self::Warm => 2,
            Self::Hatch => 3,
            Self::Feed => 4,
            Self::Transfer => 5,
            Self::Grow => 6,
            Self::Die => 7,
            Self::Name => 8,
            Self::Sleep => 9,
            Self::Wake => 10,
            Self::SpecialFeed => 11,
        }
    }
    fn requires_owner(self) -> bool {
        self != Self::Die
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WyrmCell {
    pub covenant_id: String,
    pub transaction_id: String,
    pub index: u32,
    pub value_sompi: u64,
    pub block_daa_score: u64,
    pub script_public_key: String,
    pub state: WyrmState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WyrmTransitionRequest {
    pub sender: String,
    pub action: WyrmAction,
    pub cell: WyrmCell,
    pub fee_rate: f64,
    pub action_utxos_json: String,
    #[serde(default)]
    pub recipient: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub special_feed_kind: u8,
    #[serde(default)]
    pub specialization: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedWyrmTransition {
    pub sender: String,
    pub action: WyrmAction,
    pub covenant_id: String,
    pub serial: u16,
    pub element: u8,
    pub previous_state: WyrmState,
    pub next_state: WyrmState,
    pub action_daa_score: u64,
    pub fee_sompi: u64,
    pub mass: u64,
    pub storage_mass: u64,
    pub template_hash: String,
    pub review_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedWyrmTransition {
    pub transaction_id: String,
    pub covenant_id: String,
    pub output_address: String,
    pub script_public_key: String,
    pub value_sompi: u64,
    pub submit_json: String,
    pub wrpc_json: String,
    pub fee_sompi: u64,
    pub review_hash: String,
    pub next_state: WyrmState,
}

struct Built {
    tx: Transaction,
    entries: Vec<UtxoEntry>,
    current: CompiledContract<'static>,
    review: PreparedWyrmTransition,
}

pub fn prepare(request: &WyrmTransitionRequest) -> Result<PreparedWyrmTransition> {
    Ok(build(request)?.review)
}

pub fn sign(
    secret: &str,
    request: &WyrmTransitionRequest,
    approved_review_hash: &str,
) -> Result<SignedWyrmTransition> {
    if !controls_address(secret, &request.sender)? {
        return Err(CoreError::InvalidRequest(
            "key does not control Wyrm action funding".into(),
        ));
    }
    let mut built = build(request)?;
    if built.review.review_hash != approved_review_hash {
        return Err(CoreError::ReviewMismatch);
    }
    let key = derive_key(secret)?;
    let keypair =
        Keypair::from_seckey_slice(SECP256K1, key.as_ref()).map_err(|_| CoreError::Derivation)?;
    let reused = SigHashReusedValuesUnsync::new();
    let populated = PopulatedTransaction::new(&built.tx, built.entries.clone());
    let owner_signature = if request.action.requires_owner() {
        sign_hash(&keypair, &populated, 0, &reused)?
    } else {
        vec![]
    };
    built.tx.inputs[0].signature_script = transition_sigscript(
        &built.current,
        &built.review.next_state,
        request.action.code(),
        request.special_feed_kind,
        owner_signature,
    )?;
    let populated = PopulatedTransaction::new(&built.tx, built.entries.clone());
    let funding_signature = sign_hash(&keypair, &populated, 1, &reused)?;
    built.tx.inputs[1].signature_script = ScriptBuilder::new()
        .add_data(&funding_signature)
        .map_err(|error| CoreError::Transaction(error.to_string()))?
        .drain();
    built.tx.set_storage_mass(built.review.storage_mass);
    built.tx.finalize();
    simulate_all(&built.tx, &built.entries)?;
    let output = &built.tx.outputs[0];
    let output_address = extract_script_pub_key_address(&output.script_public_key, Prefix::Mainnet)
        .map_err(|_| CoreError::InvalidAddress)?
        .to_string();
    Ok(SignedWyrmTransition {
        transaction_id: built.tx.id().to_string(),
        covenant_id: built.review.covenant_id.clone(),
        output_address,
        script_public_key: hex::encode(output.script_public_key.script()),
        value_sompi: output.value,
        submit_json: submit_json_v1(&built.tx)?,
        wrpc_json: wrpc_safe_json(&built.tx, &built.entries)?,
        fee_sompi: built.review.fee_sompi,
        review_hash: built.review.review_hash,
        next_state: built.review.next_state,
    })
}

fn build(request: &WyrmTransitionRequest) -> Result<Built> {
    if !request.fee_rate.is_finite() || !(100.0..=10_000.0).contains(&request.fee_rate) {
        return Err(CoreError::InvalidRequest(
            "Wyrm fee rate is out of range".into(),
        ));
    }
    let sender =
        Address::try_from(request.sender.as_str()).map_err(|_| CoreError::InvalidAddress)?;
    if sender.prefix != Prefix::Mainnet
        || sender.version != AddressVersion::PubKey
        || sender.payload.len() != 32
    {
        return Err(CoreError::InvalidRequest(
            "Wyrm transitions require a Mainnet P2PK owner".into(),
        ));
    }
    let owner: [u8; 32] = sender
        .payload
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::InvalidAddress)?;
    if request.action.requires_owner() && request.cell.state.owner != owner {
        return Err(CoreError::InvalidRequest(
            "Wyrm state belongs to a different owner".into(),
        ));
    }
    let covenant_id = Hash::from_str(&request.cell.covenant_id)
        .map_err(|_| CoreError::UntrustedUtxo("invalid Wyrm covenant ID".into()))?;
    let cell_txid = TransactionId::from_str(&request.cell.transaction_id)
        .map_err(|_| CoreError::UntrustedUtxo("invalid Wyrm transaction ID".into()))?;
    if request.cell.value_sompi < DUST_SOMPI {
        return Err(CoreError::UntrustedUtxo(
            "Wyrm reserve is below dust".into(),
        ));
    }
    let current = compile_state(request.cell.state)?;
    if hex::encode(current.template_hash()) != template_hash()? {
        return Err(CoreError::UntrustedUtxo("Wyrm template mismatch".into()));
    }
    let expected_script = pay_to_script_hash_script(&current.script);
    let supplied_script = hex::decode(&request.cell.script_public_key)
        .map_err(|_| CoreError::UntrustedUtxo("invalid Wyrm script".into()))?;
    if supplied_script.as_slice() != expected_script.script() {
        return Err(CoreError::UntrustedUtxo(
            "Wyrm state does not match live script".into(),
        ));
    }

    let mut action_utxos = parse_utxos(&request.action_utxos_json, &sender)?;
    action_utxos.sort_by_key(|item| item.entry.amount);
    let action_funding = action_utxos
        .into_iter()
        .find(|item| item.outpoint != TransactionOutpoint::new(cell_txid, request.cell.index))
        .ok_or(CoreError::InsufficientFunds)?;
    if action_funding.entry.block_daa_score == 0 {
        return Err(CoreError::UntrustedUtxo(
            "action UTXO is not confirmed".into(),
        ));
    }
    let action_daa = action_funding.entry.block_daa_score;
    let next_state = next_state(request, action_daa)?;
    let next = compile_state(next_state)?;
    let cell_entry = UtxoEntry::new(
        request.cell.value_sompi,
        expected_script,
        request.cell.block_daa_score,
        false,
        Some(covenant_id),
    );
    let entries = vec![cell_entry, action_funding.entry.clone()];
    let calculator = MassCalculator::new_with_consensus_params(&MAINNET_PARAMS);
    let limits = MAINNET_PARAMS.mempool_block_mass_limits().after();
    let storage_target = limits.storage.saturating_mul(STORAGE_LIMIT_PERCENT) / 100;
    let mut fee = 0u64;
    for _ in 0..12 {
        let change = action_funding
            .entry
            .amount
            .checked_sub(fee)
            .ok_or(CoreError::InsufficientFunds)?;
        if change < DUST_SOMPI {
            return Err(CoreError::InsufficientFunds);
        }
        let mut tx = Transaction::new(
            TX_VERSION_TOCCATA,
            vec![
                TransactionInput::new_with_mass(TransactionOutpoint::new(cell_txid, request.cell.index), vec![], 0, ComputeCommit::ComputeBudget(ComputeBudget(WYRM_COMPUTE_BUDGET))),
                TransactionInput::new_with_mass(action_funding.outpoint, vec![], 0, ComputeCommit::ComputeBudget(ComputeBudget(FUNDING_COMPUTE_BUDGET))),
            ],
            vec![
                TransactionOutput::with_covenant(request.cell.value_sompi, pay_to_script_hash_script(&next.script), Some(CovenantBinding::new(0, covenant_id))),
                TransactionOutput::new(change, pay_to_address_script(&sender)),
            ],
            0,
            SUBNETWORK_ID_NATIVE,
            0,
            serde_json::to_vec(&json!({"p":"gothdag-covenant-wyrm-v1","action":request.action,"serial":request.cell.state.serial,"covenantId":request.cell.covenant_id})).map_err(|_| CoreError::Serialization)?,
        );
        tx.inputs[0].signature_script = transition_sigscript(
            &current,
            &next_state,
            request.action.code(),
            request.special_feed_kind,
            if request.action.requires_owner() {
                vec![0; 65]
            } else {
                vec![]
            },
        )?;
        tx.inputs[1].signature_script = ScriptBuilder::new()
            .add_data(&[0u8; 65])
            .map_err(|error| CoreError::Transaction(error.to_string()))?
            .drain();
        let populated = PopulatedTransaction::new(&tx, entries.clone());
        let non_contextual = calculator.calc_non_contextual_masses(&tx);
        let contextual = calculator
            .calc_contextual_masses(&populated)
            .ok_or_else(|| {
                CoreError::Transaction("Wyrm storage mass cannot be calculated".into())
            })?;
        let cofactors = MAINNET_PARAMS.mempool_block_mass_cofactors().after();
        let transient = (non_contextual.transient_mass as f64 * cofactors.transient).ceil() as u64;
        let mass = Mass::new(
            non_contextual,
            ContextualMasses::new(contextual.storage_mass),
        )
        .normalized_max(&cofactors);
        if mass > limits.reference() || contextual.storage_mass > storage_target {
            return Err(CoreError::Transaction(
                "Wyrm transition exceeds safe mass limits".into(),
            ));
        }
        let required_fee =
            (request.fee_rate * non_contextual.compute_mass.max(transient) as f64).ceil() as u64;
        if fee < required_fee {
            fee = required_fee;
            continue;
        }
        tx.set_storage_mass(contextual.storage_mass);
        tx.finalize();
        let review_value = json!({
            "network":"kaspa:mainnet","profile":"covenant-wyrm-transition-v1","sender":request.sender,"action":request.action,
            "covenantId":request.cell.covenant_id.to_lowercase(),"serial":request.cell.state.serial,"element":request.cell.state.element,
            "previousState":request.cell.state,"nextState":next_state,"actionDaaScore":action_daa,"feeSompi":fee,
            "mass":mass,"storageMass":contextual.storage_mass,
            "inputs":tx.inputs.iter().map(|input| json!({"transactionId":input.previous_outpoint.transaction_id.to_string(),"index":input.previous_outpoint.index})).collect::<Vec<_>>(),
            "outputs":tx.outputs.iter().map(|output| json!({"amountSompi":output.value,"script":hex::encode(output.script_public_key.script()),"covenantId":output.covenant.map(|binding| binding.covenant_id.to_string())})).collect::<Vec<_>>()
        });
        let review_hash = hex::encode(Sha256::digest(
            serde_json::to_vec(&review_value).map_err(|_| CoreError::Serialization)?,
        ));
        return Ok(Built {
            tx,
            entries,
            current,
            review: PreparedWyrmTransition {
                sender: request.sender.clone(),
                action: request.action,
                covenant_id: request.cell.covenant_id.to_lowercase(),
                serial: request.cell.state.serial,
                element: request.cell.state.element,
                previous_state: request.cell.state,
                next_state,
                action_daa_score: action_daa,
                fee_sompi: fee,
                mass,
                storage_mass: contextual.storage_mass,
                template_hash: template_hash()?,
                review_hash,
            },
        });
    }
    Err(CoreError::InsufficientFunds)
}

fn next_state(request: &WyrmTransitionRequest, action_daa: u64) -> Result<WyrmState> {
    let previous = request.cell.state;
    if action_daa < previous.anchor_daa {
        return Err(CoreError::InvalidRequest(
            "Wyrm action clock predates its current state".into(),
        ));
    }
    let elapsed = action_daa - previous.anchor_daa;
    let valid = match request.action {
        WyrmAction::Incubate => previous.phase == 0,
        WyrmAction::Warm => previous.phase == 1 && !previous.warmed && elapsed >= TWELVE_HOURS_DAA,
        WyrmAction::Hatch => previous.phase == 1 && previous.warmed && elapsed >= TWELVE_HOURS_DAA,
        WyrmAction::Feed => {
            previous.phase == 2
                && (DAY_DAA..THREE_DAYS_DAA).contains(&elapsed)
                && request.special_feed_kind == 0
        }
        WyrmAction::SpecialFeed => {
            previous.phase == 2
                && (DAY_DAA..THREE_DAYS_DAA).contains(&elapsed)
                && (1..=5).contains(&request.special_feed_kind)
        }
        WyrmAction::Transfer => matches!(previous.phase, 0 | 3),
        WyrmAction::Grow => {
            previous.phase == 2
                && match previous.growth_stage {
                    0 => previous.care_points >= 7 && previous.active_days >= 7,
                    1 => previous.care_points >= 21 && previous.active_days >= 21,
                    2 => previous.care_points >= 69 && previous.active_days >= 69,
                    _ => false,
                }
        }
        WyrmAction::Die => previous.phase == 2 && elapsed >= THREE_DAYS_DAA,
        WyrmAction::Name => previous.phase == 2,
        WyrmAction::Sleep => previous.phase == 2 && elapsed < THREE_DAYS_DAA,
        WyrmAction::Wake => {
            previous.phase == 3
                && previous.sleep_started_daa >= previous.anchor_daa
                && action_daa.saturating_sub(previous.sleep_started_daa) >= DAY_DAA
        }
    };
    if !valid {
        return Err(CoreError::InvalidRequest(
            "Wyrm action is not valid in its current state or time window".into(),
        ));
    }
    let mut next = previous;
    match request.action {
        WyrmAction::Incubate => {
            next.phase = 1;
            next.warmed = false;
            next.anchor_daa = action_daa;
        }
        WyrmAction::Warm => {
            next.warmed = true;
            next.anchor_daa = action_daa;
        }
        WyrmAction::Hatch => {
            next.phase = 2;
            next.growth_stage = 0;
            next.anchor_daa = action_daa;
        }
        WyrmAction::Feed => {
            next.care_points = next
                .care_points
                .checked_add(1)
                .ok_or_else(|| CoreError::InvalidRequest("care point overflow".into()))?;
            next.active_days = next
                .active_days
                .checked_add(1)
                .ok_or_else(|| CoreError::InvalidRequest("active day overflow".into()))?;
            next.anchor_daa = action_daa;
        }
        WyrmAction::SpecialFeed => {
            next.care_points = next
                .care_points
                .checked_add(1)
                .ok_or_else(|| CoreError::InvalidRequest("care point overflow".into()))?;
            next.active_days = next
                .active_days
                .checked_add(1)
                .ok_or_else(|| CoreError::InvalidRequest("active day overflow".into()))?;
            match request.special_feed_kind {
                1 => {
                    next.bone_feeds = next.bone_feeds.checked_add(1).ok_or_else(|| {
                        CoreError::InvalidRequest("special feed counter overflow".into())
                    })?
                }
                2 => {
                    next.blood_feeds = next.blood_feeds.checked_add(1).ok_or_else(|| {
                        CoreError::InvalidRequest("special feed counter overflow".into())
                    })?
                }
                3 => {
                    next.moon_feeds = next.moon_feeds.checked_add(1).ok_or_else(|| {
                        CoreError::InvalidRequest("special feed counter overflow".into())
                    })?
                }
                4 => {
                    next.teal_feeds = next.teal_feeds.checked_add(1).ok_or_else(|| {
                        CoreError::InvalidRequest("special feed counter overflow".into())
                    })?
                }
                5 => {
                    next.night_feeds = next.night_feeds.checked_add(1).ok_or_else(|| {
                        CoreError::InvalidRequest("special feed counter overflow".into())
                    })?
                }
                _ => return Err(CoreError::InvalidRequest("invalid special feed".into())),
            };
            next.anchor_daa = action_daa;
        }
        WyrmAction::Transfer => {
            let recipient = Address::try_from(request.recipient.as_str())
                .map_err(|_| CoreError::InvalidAddress)?;
            if recipient.prefix != Prefix::Mainnet
                || recipient.version != AddressVersion::PubKey
                || recipient.payload.len() != 32
            {
                return Err(CoreError::InvalidAddress);
            }
            next.owner = recipient
                .payload
                .as_slice()
                .try_into()
                .map_err(|_| CoreError::InvalidAddress)?;
            if next.owner == previous.owner {
                return Err(CoreError::InvalidRequest(
                    "Wyrm recipient must differ from its current owner".into(),
                ));
            }
        }
        WyrmAction::Grow => {
            next.growth_stage = next
                .growth_stage
                .checked_add(1)
                .ok_or_else(|| CoreError::InvalidRequest("growth stage overflow".into()))?;
            if next.growth_stage == 2 {
                let counts = [
                    previous.bone_feeds,
                    previous.blood_feeds,
                    previous.moon_feeds,
                    previous.teal_feeds,
                    previous.night_feeds,
                ];
                let maximum = *counts.iter().max().unwrap_or(&0);
                if maximum == 0 {
                    next.specialization = 0;
                } else {
                    let candidates: Vec<u8> = counts
                        .iter()
                        .enumerate()
                        .filter_map(|(index, count)| (*count == maximum).then_some(index as u8 + 1))
                        .collect();
                    if candidates.len() == 1 {
                        next.specialization = candidates[0];
                    } else if candidates.contains(&request.specialization) {
                        next.specialization = request.specialization;
                    } else {
                        return Err(CoreError::InvalidRequest(
                            "Choose one of the tied Wyrm specializations".into(),
                        ));
                    }
                }
            }
        }
        WyrmAction::Die => {
            next.phase = 4;
        }
        WyrmAction::Name => {
            let name = request.name.trim();
            if name.is_empty() || name.as_bytes().len() > 32 {
                return Err(CoreError::InvalidRequest(
                    "Wyrm name must contain 1 to 32 bytes".into(),
                ));
            }
            next.name_hash = Sha256::digest(name.to_lowercase().as_bytes()).into();
            if next.name_hash == previous.name_hash {
                return Err(CoreError::InvalidRequest("Wyrm name is unchanged".into()));
            }
        }
        WyrmAction::Sleep => {
            next.phase = 3;
            next.sleep_started_daa = action_daa;
        }
        WyrmAction::Wake => {
            let elapsed_before_sleep = next
                .sleep_started_daa
                .checked_sub(next.anchor_daa)
                .ok_or_else(|| CoreError::InvalidRequest("invalid Wyrm sleep clock".into()))?;
            next.phase = 2;
            next.anchor_daa = action_daa
                .checked_sub(elapsed_before_sleep)
                .ok_or_else(|| CoreError::InvalidRequest("invalid Wyrm wake clock".into()))?;
            next.sleep_started_daa = 0;
        }
    }
    Ok(next)
}

fn state_expr(state: &WyrmState) -> Expr<'static> {
    struct_object(vec![
        ("owner", Expr::bytes(state.owner.to_vec())),
        ("serial", Expr::int(i64::from(state.serial))),
        ("element", Expr::byte(state.element)),
        ("phase", Expr::byte(state.phase)),
        ("warmed", Expr::bool(state.warmed)),
        ("carePoints", Expr::int(i64::from(state.care_points))),
        ("activeDays", Expr::int(i64::from(state.active_days))),
        ("growthStage", Expr::byte(state.growth_stage)),
        ("specialization", Expr::byte(state.specialization)),
        ("nameHash", Expr::bytes(state.name_hash.to_vec())),
        (
            "anchorDaa",
            Expr::int(i64::try_from(state.anchor_daa).unwrap_or(i64::MAX)),
        ),
        (
            "sleepStartedDaa",
            Expr::int(i64::try_from(state.sleep_started_daa).unwrap_or(i64::MAX)),
        ),
        ("boneFeeds", Expr::int(i64::from(state.bone_feeds))),
        ("bloodFeeds", Expr::int(i64::from(state.blood_feeds))),
        ("moonFeeds", Expr::int(i64::from(state.moon_feeds))),
        ("tealFeeds", Expr::int(i64::from(state.teal_feeds))),
        ("nightFeeds", Expr::int(i64::from(state.night_feeds))),
    ])
}

fn transition_sigscript(
    compiled: &CompiledContract<'static>,
    next: &WyrmState,
    action: u8,
    special_feed_kind: u8,
    owner_signature: Vec<u8>,
) -> Result<Vec<u8>> {
    let mut script = compiled
        .build_sig_script_for_covenant_decl(
            "transition",
            vec![
                state_expr(next),
                Expr::byte(action),
                Expr::byte(special_feed_kind),
                Expr::int(1),
                Expr::bytes(owner_signature),
            ],
            CovenantDeclCallOptions { is_leader: true },
        )
        .map_err(|error| CoreError::Transaction(format!("Wyrm witness failed: {error}")))?;
    let redeem = ScriptBuilder::with_flags(EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    })
    .add_data(&compiled.script)
    .map_err(|error| CoreError::Transaction(error.to_string()))?
    .drain();
    script.extend_from_slice(&redeem);
    Ok(script)
}

fn sign_hash(
    keypair: &Keypair,
    transaction: &PopulatedTransaction<'_>,
    input_index: usize,
    reused: &SigHashReusedValuesUnsync,
) -> Result<Vec<u8>> {
    let hash = calc_schnorr_signature_hash(transaction, input_index, SIG_HASH_ALL, reused);
    let message = Message::from_digest_slice(hash.as_bytes().as_slice())
        .map_err(|error| CoreError::Transaction(error.to_string()))?;
    let mut signature = keypair.sign_schnorr(message).as_ref().to_vec();
    signature.push(SIG_HASH_ALL.to_u8());
    Ok(signature)
}
