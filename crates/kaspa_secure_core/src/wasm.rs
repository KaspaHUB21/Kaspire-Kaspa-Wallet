use super::*;
use serde::Serialize;
use wasm_bindgen::prelude::*;

fn json<T: Serialize>(value: Result<T>) -> std::result::Result<String, JsError> {
    value
        .and_then(|item| serde_json::to_string(&item).map_err(|_| CoreError::Serialization))
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = generateWallet)]
pub fn generate_wallet_js(passphrase: &str) -> std::result::Result<String, JsError> {
    json(generate_wallet_with_passphrase(passphrase))
}

#[wasm_bindgen(js_name = generateWalletWithWordCount)]
pub fn generate_wallet_with_word_count_js(
    passphrase: &str,
    word_count: usize,
) -> std::result::Result<String, JsError> {
    json(generate_wallet_with_word_count(passphrase, word_count))
}

#[wasm_bindgen(js_name = importWallet)]
pub fn import_wallet_js(phrase: &str, passphrase: &str) -> std::result::Result<String, JsError> {
    json(import_wallet_with_passphrase(phrase, passphrase))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MnemonicWordStatus {
    invalid_words: Vec<String>,
    suggestions: Vec<String>,
}

#[wasm_bindgen(js_name = mnemonicWordStatus)]
pub fn mnemonic_word_status_js(phrase: &str) -> std::result::Result<String, JsError> {
    let normalized = phrase.to_ascii_lowercase();
    let words: Vec<&str> = normalized.split_whitespace().collect();
    let list = Language::English.wordlist();
    let invalid_words = words
        .iter()
        .filter(|word| !list.iter().any(|candidate| candidate == **word))
        .map(|word| (*word).to_owned())
        .collect();
    let prefix = normalized
        .split(|character: char| character.is_whitespace())
        .next_back()
        .unwrap_or_default();
    let suggestions = if prefix.len() >= 2 && !list.iter().any(|word| word == prefix) {
        list.iter()
            .filter(|word| word.starts_with(prefix))
            .take(8)
            .map(|word| (*word).to_owned())
            .collect()
    } else {
        Vec::new()
    };
    serde_json::to_string(&MnemonicWordStatus {
        invalid_words,
        suggestions,
    })
    .map_err(|_| JsError::new("could not encode word status"))
}

#[wasm_bindgen(js_name = importPrivateKey)]
pub fn import_private_key_js(value: &str) -> std::result::Result<String, JsError> {
    json(import_private_key(value))
}

#[wasm_bindgen(js_name = deriveBackupKey)]
pub fn derive_backup_key_js(
    password: &str,
    salt_hex: &str,
) -> std::result::Result<String, JsError> {
    let salt = hex::decode(salt_hex).map_err(|_| JsError::new("invalid backup salt"))?;
    derive_backup_key(password, &salt)
        .map(|key| hex::encode(key.as_ref()))
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = deriveAddressRange)]
pub fn derive_address_range_js(
    secret: &str,
    coin_type: u32,
    account: u32,
    change: u32,
    start: u32,
    count: u32,
) -> std::result::Result<String, JsError> {
    json(derive_address_range(
        secret, coin_type, account, change, start, count,
    ))
}

#[wasm_bindgen(js_name = addressWithPrefix)]
pub fn address_with_prefix_js(
    address: &str,
    testnet: bool,
) -> std::result::Result<String, JsError> {
    address_with_prefix(address, testnet).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = deriveEvmAddress)]
pub fn derive_evm_address_js(secret: &str) -> std::result::Result<String, JsError> {
    derive_evm_address(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = exportEvmPrivateKey)]
pub fn export_evm_private_key_js(secret: &str) -> std::result::Result<String, JsError> {
    export_evm_private_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareEvmTransaction)]
pub fn prepare_evm_transaction_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid EVM request"))?;
    json(prepare_evm_transaction(&request))
}

#[wasm_bindgen(js_name = signEvmTransaction)]
pub fn sign_evm_transaction_js(secret: &str, request: &str, review_hash: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid EVM request"))?;
    json(sign_evm_transaction(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = exportPrivateKey)]
pub fn export_private_key_js(secret: &str) -> std::result::Result<String, JsError> {
    export_private_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = publicKey)]
pub fn public_key_js(secret: &str) -> std::result::Result<String, JsError> {
    public_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareTransaction)]
pub fn prepare_transaction_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(prepare_transaction(&request))
}

#[wasm_bindgen(js_name = signTransaction)]
pub fn sign_transaction_js(
    secret: &str,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(sign_transaction(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = signPersonalMessage)]
pub fn sign_personal_message_js(
    secret: &str,
    address: &str,
    message: &str,
) -> std::result::Result<String, JsError> {
    sign_personal_message(secret, address, message)
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = preparePskt)]
pub fn prepare_pskt_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(prepare_pskt(&request))
}

#[wasm_bindgen(js_name = signPskt)]
pub fn sign_pskt_js(
    secret: &str,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(sign_pskt(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = prepareInscription)]
pub fn prepare_inscription_js(request: &str) -> std::result::Result<String, JsError> {
    let request =
        serde_json::from_str(request).map_err(|_| JsError::new("invalid inscription request"))?;
    json(prepare_inscription(&request))
}

#[wasm_bindgen(js_name = prepareReveal)]
pub fn prepare_reveal_js(request: &str) -> std::result::Result<String, JsError> {
    let request =
        serde_json::from_str(request).map_err(|_| JsError::new("invalid reveal request"))?;
    json(prepare_reveal(&request))
}

#[wasm_bindgen(js_name = signReveal)]
pub fn sign_reveal_js(
    secret: &str,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let request =
        serde_json::from_str(request).map_err(|_| JsError::new("invalid reveal request"))?;
    json(sign_reveal(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = prepareKcc20Transfer)]
pub fn prepare_kcc20_transfer_js(request: &str) -> std::result::Result<String, JsError> {
    let request =
        serde_json::from_str(request).map_err(|_| JsError::new("invalid KCC20 request"))?;
    json(prepare_kcc20_transfer(&request))
}

#[wasm_bindgen(js_name = signKcc20Transfer)]
pub fn sign_kcc20_transfer_js(
    secret: &str,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let request =
        serde_json::from_str(request).map_err(|_| JsError::new("invalid KCC20 request"))?;
    json(sign_kcc20_transfer(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = preparePolicyTransaction)]
pub fn prepare_policy_transaction_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request)
        .map_err(|_| JsError::new("invalid policy transaction request"))?;
    json(prepare_policy_transaction(&request))
}

#[wasm_bindgen(js_name = signPolicyTransaction)]
pub fn sign_policy_transaction_js(
    secret: &str,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request)
        .map_err(|_| JsError::new("invalid policy transaction request"))?;
    json(sign_policy_transaction(secret, &request, review_hash))
}
