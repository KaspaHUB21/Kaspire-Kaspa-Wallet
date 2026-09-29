use crate::covenant_wyrm::{compile_state, WyrmState};
use crate::{
    derive_address, prepare_wyrm_transition, sign_wyrm_transition, WyrmAction, WyrmCell,
    WyrmTransitionRequest,
};
use kaspa_addresses::Address;
use kaspa_txscript::{pay_to_address_script, pay_to_script_hash_script};
use serde_json::json;

fn fixture(action: WyrmAction, action_daa: u64) -> (String, WyrmTransitionRequest) {
    let secret =
        "private:0000000000000000000000000000000000000000000000000000000000000001".to_string();
    let sender = derive_address(&secret).unwrap();
    let owner: [u8; 32] = Address::try_from(sender.to_string())
        .unwrap()
        .payload
        .as_slice()
        .try_into()
        .unwrap();
    let state = WyrmState {
        owner,
        serial: 1,
        element: 0,
        phase: 0,
        warmed: false,
        care_points: 0,
        active_days: 0,
        growth_stage: 0,
        specialization: 0,
        name_hash: [0; 32],
        anchor_daa: 0,
        sleep_started_daa: 0,
        bone_feeds: 0,
        blood_feeds: 0,
        moon_feeds: 0,
        teal_feeds: 0,
        night_feeds: 0,
    };
    let compiled = compile_state(state).unwrap();
    let action_script = pay_to_address_script(&sender);
    let funding = json!([{
        "address": sender.to_string(),
        "outpoint": {"transactionId":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","index":0},
        "utxoEntry": {"amount":"100000000","blockDaaScore":action_daa.to_string(),"isCoinbase":false,
            "scriptPublicKey":{"scriptPublicKey":hex::encode(action_script.script())}}
    }]).to_string();
    let request = WyrmTransitionRequest {
        sender: sender.to_string(),
        action,
        cell: WyrmCell {
            covenant_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
            transaction_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                .into(),
            index: 0,
            value_sompi: 100_000_000,
            block_daa_score: 1,
            script_public_key: hex::encode(pay_to_script_hash_script(&compiled.script).script()),
            state,
        },
        fee_rate: 100.0,
        action_utxos_json: funding,
        recipient: String::new(),
        name: String::new(),
        special_feed_kind: 0,
        specialization: 0,
    };
    (secret, request)
}

#[test]
fn builds_signs_and_locally_executes_incubation_transition() {
    let (secret, request) = fixture(WyrmAction::Incubate, 100);
    let prepared = prepare_wyrm_transition(&request).unwrap();
    assert_eq!(prepared.next_state.phase, 1);
    assert_eq!(prepared.next_state.anchor_daa, 100);
    let signed = sign_wyrm_transition(&secret, &request, &prepared.review_hash).unwrap();
    assert_eq!(signed.covenant_id, request.cell.covenant_id);
    assert!(signed.wrpc_json.contains("computeBudget"));
}

#[test]
fn crystal_sleep_preserves_elapsed_life_and_requires_a_full_day() {
    let (secret, mut request) = fixture(WyrmAction::Sleep, 500_000);
    request.cell.state.phase = 2;
    request.cell.state.anchor_daa = 100_000;
    let current = compile_state(request.cell.state).unwrap();
    request.cell.script_public_key =
        hex::encode(pay_to_script_hash_script(&current.script).script());
    let prepared = prepare_wyrm_transition(&request).unwrap();
    assert_eq!(prepared.next_state.phase, 3);
    assert_eq!(prepared.next_state.sleep_started_daa, 500_000);
    sign_wyrm_transition(&secret, &request, &prepared.review_hash).unwrap();

    let mut wake = request;
    wake.action = WyrmAction::Wake;
    wake.cell.state = prepared.next_state;
    wake.cell.transaction_id =
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc".into();
    wake.cell.script_public_key = hex::encode(
        pay_to_script_hash_script(&compile_state(wake.cell.state).unwrap().script).script(),
    );
    let too_early = 500_000 + 864_000 - 1;
    wake.action_utxos_json = wake
        .action_utxos_json
        .replace("500000", &too_early.to_string());
    assert!(prepare_wyrm_transition(&wake).is_err());

    wake.action_utxos_json = wake
        .action_utxos_json
        .replace(&too_early.to_string(), &(500_000 + 864_000).to_string());
    let prepared_wake = prepare_wyrm_transition(&wake).unwrap();
    assert_eq!(prepared_wake.next_state.phase, 2);
    assert_eq!(prepared_wake.next_state.sleep_started_daa, 0);
    assert_eq!(prepared_wake.next_state.anchor_daa, 964_000);
}

#[test]
fn living_wyrm_must_sleep_before_transfer() {
    let (_, mut request) = fixture(WyrmAction::Transfer, 200_000);
    request.cell.state.phase = 2;
    request.cell.state.anchor_daa = 100_000;
    request.recipient =
        derive_address("private:0000000000000000000000000000000000000000000000000000000000000002")
            .unwrap()
            .to_string();
    request.cell.script_public_key = hex::encode(
        pay_to_script_hash_script(&compile_state(request.cell.state).unwrap().script).script(),
    );
    assert!(prepare_wyrm_transition(&request).is_err());
}

#[test]
fn special_feed_updates_only_the_selected_development_path() {
    let (secret, mut request) = fixture(WyrmAction::SpecialFeed, 864_100);
    request.cell.state.phase = 2;
    request.cell.state.anchor_daa = 100;
    request.special_feed_kind = 4;
    request.cell.script_public_key = hex::encode(
        pay_to_script_hash_script(&compile_state(request.cell.state).unwrap().script).script(),
    );
    let prepared = prepare_wyrm_transition(&request).unwrap();
    assert_eq!(prepared.next_state.teal_feeds, 1);
    assert_eq!(prepared.next_state.bone_feeds, 0);
    assert_eq!(prepared.next_state.care_points, 1);
    assert_eq!(prepared.next_state.active_days, 1);
    sign_wyrm_transition(&secret, &request, &prepared.review_hash).unwrap();
}

#[test]
fn adult_growth_requires_a_highest_or_tied_specialization() {
    let (secret, mut request) = fixture(WyrmAction::Grow, 900_000);
    request.cell.state.phase = 2;
    request.cell.state.anchor_daa = 100;
    request.cell.state.growth_stage = 1;
    request.cell.state.care_points = 21;
    request.cell.state.active_days = 21;
    request.cell.state.bone_feeds = 3;
    request.cell.state.blood_feeds = 3;
    request.cell.state.moon_feeds = 1;
    request.specialization = 2;
    request.cell.script_public_key = hex::encode(
        pay_to_script_hash_script(&compile_state(request.cell.state).unwrap().script).script(),
    );
    let prepared = prepare_wyrm_transition(&request).unwrap();
    assert_eq!(prepared.next_state.growth_stage, 2);
    assert_eq!(prepared.next_state.specialization, 2);
    sign_wyrm_transition(&secret, &request, &prepared.review_hash).unwrap();

    request.specialization = 4;
    assert!(prepare_wyrm_transition(&request).is_err());
}

#[test]
fn transition_review_rejects_mutation() {
    let (secret, request) = fixture(WyrmAction::Incubate, 100);
    let prepared = prepare_wyrm_transition(&request).unwrap();
    let mut changed = request.clone();
    changed.action = WyrmAction::Feed;
    assert!(sign_wyrm_transition(&secret, &changed, &prepared.review_hash).is_err());
    assert!(sign_wyrm_transition(&secret, &request, "00").is_err());
}
