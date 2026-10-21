use super::*;
use serde::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = secretBoundaryVersion)]
pub fn secret_boundary_version_js() -> u32 {
    1
}

#[wasm_bindgen(js_name = deriveHiddenKas)]
pub fn derive_hidden_kas_js(
    secret: Vec<u8>,
    branch: u32,
    start: u32,
    count: u32,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    json(crate::hidden_kas::derive(secret, branch, start, count))
}
#[wasm_bindgen(js_name = validateHiddenKasUtxos)]
pub fn validate_hidden_kas_utxos_js(
    secret: Vec<u8>,
    raw_address: &str,
    rows: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    if rows.len() > 2 * 1024 * 1024 || raw_address.len() > 1024 {
        return Err(JsError::new("P2SH output response is too large"));
    }
    let address: crate::hidden_kas::HiddenAddress =
        serde_json::from_str(raw_address).map_err(|_| JsError::new("Invalid P2SH address"))?;
    let owned = crate::hidden_kas::derive(secret, address.branch, address.index, 1)
        .map_err(|e| JsError::new(&e.to_string()))?;
    if owned.first() != Some(&address) {
        return Err(JsError::new(
            "P2SH address does not belong to the active seed",
        ));
    }
    let parsed = kaspa_addresses::Address::try_from(address.address.as_str())
        .map_err(|_| JsError::new("Invalid P2SH address"))?;
    let entries =
        crate::transaction::parse_utxos(rows, &parsed).map_err(|e| JsError::new(&e.to_string()))?;
    let total = entries
        .iter()
        .try_fold(0u64, |sum, entry| sum.checked_add(entry.entry.amount))
        .ok_or_else(|| JsError::new("P2SH balance overflow"))?;
    Ok(total.to_string())
}
#[wasm_bindgen(js_name = prepareHiddenKas)]
pub fn prepare_hidden_kas_js(secret: Vec<u8>, raw: &str) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_value(vault_input(raw)?)
        .map_err(|_| JsError::new("Invalid P2SH payment request"))?;
    vault_json(crate::hidden_kas::prepare(secret, &request))
}
#[wasm_bindgen(js_name = signHiddenKas)]
pub fn sign_hidden_kas_js(
    secret: Vec<u8>,
    raw: &str,
    hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_value(vault_input(raw)?)
        .map_err(|_| JsError::new("Invalid P2SH payment request"))?;
    vault_json(crate::hidden_kas::sign(secret, &request, hash))
}
#[wasm_bindgen(js_name = verifyHiddenKasRecovery)]
pub fn verify_hidden_kas_recovery_js(
    secret: Vec<u8>,
    raw: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let saved = vault_input(raw)?;
    crate::hidden_kas::verify_saved(secret, &saved).map_err(|e| JsError::new(&e.to_string()))?;
    Ok("true".into())
}

// Chrome messages cannot carry BigInt. Preserve large sompi amounts as decimal
// strings at the JS boundary, while the shared native core still uses exact u64.
fn vault_input(raw: &str) -> std::result::Result<serde_json::Value, JsError> {
    if raw.len() > 2 * 1024 * 1024 {
        return Err(JsError::new("Vault request is too large"));
    }
    let mut value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| JsError::new("Invalid vault request"))?;
    fn convert(v: &mut serde_json::Value) -> std::result::Result<(), JsError> {
        match v {
            serde_json::Value::Object(fields) => {
                for (key, value) in fields {
                    if [
                        "amountSompi",
                        "valueSompi",
                        "limitDaa",
                        "currentDaa",
                        "blockDaaScore",
                    ]
                    .contains(&key.as_str())
                    {
                        if let Some(text) = value.as_str() {
                            let n = text
                                .parse::<u64>()
                                .map_err(|_| JsError::new("Invalid vault integer"))?;
                            *value = serde_json::json!(n);
                        }
                    }
                    convert(value)?;
                }
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    convert(item)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    convert(&mut value)?;
    Ok(value)
}
fn vault_json(value: Result<serde_json::Value>) -> std::result::Result<String, JsError> {
    fn convert(value: &mut serde_json::Value) {
        match value {
            serde_json::Value::Number(n)
                if n.as_u64().is_some_and(|n| n > 9_007_199_254_740_991) =>
            {
                *value = serde_json::Value::String(n.to_string());
            }
            serde_json::Value::Object(fields) => {
                for value in fields.values_mut() {
                    convert(value);
                }
            }
            serde_json::Value::Array(items) => {
                for value in items {
                    convert(value);
                }
            }
            _ => {}
        }
    }
    let mut value = value.map_err(|e| JsError::new(&e.to_string()))?;
    convert(&mut value);
    Ok(value.to_string())
}
#[wasm_bindgen(js_name = describeCovenantVault)]
pub fn describe_covenant_vault_js(raw: &str) -> std::result::Result<String, JsError> {
    let terms = serde_json::from_value(vault_input(raw)?)
        .map_err(|_| JsError::new("Invalid vault terms"))?;
    vault_json(crate::covenant_vault::descriptor(&terms))
}
#[wasm_bindgen(js_name = prepareCovenantVault)]
pub fn prepare_covenant_vault_js(raw: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_value(vault_input(raw)?)
        .map_err(|_| JsError::new("Invalid vault transaction"))?;
    vault_json(crate::covenant_vault::prepare(&request))
}
#[wasm_bindgen(js_name = signCovenantVault)]
pub fn sign_covenant_vault_js(
    secret: Vec<u8>,
    raw: &str,
    hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_value(vault_input(raw)?)
        .map_err(|_| JsError::new("Invalid vault transaction"))?;
    vault_json(crate::covenant_vault::sign(secret, &request, hash))
}
#[wasm_bindgen(js_name = validateVaultRecord)]
pub fn validate_vault_record_js(raw: &str) -> std::result::Result<String, JsError> {
    vault_json(crate::vault_recovery::validate_record(
        &vault_input(raw)?.to_string(),
    ))
}
#[wasm_bindgen(js_name = sealVaultRecovery)]
pub fn seal_vault_recovery_js(
    password: &mut [u8],
    raw: &str,
) -> std::result::Result<String, JsError> {
    let owned = Zeroizing::new(password.to_vec());
    password.fill(0);
    crate::vault_recovery::seal(&owned, &vault_input(raw)?.to_string())
        .map_err(|e| JsError::new(&e.to_string()))
}
#[wasm_bindgen(js_name = openVaultRecovery)]
pub fn open_vault_recovery_js(
    password: &mut [u8],
    raw: &str,
) -> std::result::Result<String, JsError> {
    let owned = Zeroizing::new(password.to_vec());
    password.fill(0);
    let text =
        crate::vault_recovery::open(&owned, raw).map_err(|e| JsError::new(&e.to_string()))?;
    vault_json(serde_json::from_str(&text).map_err(|_| CoreError::Serialization))
}

#[wasm_bindgen(js_name = deriveDotkDeed)]
pub fn derive_dotk_deed_js(request: &str) -> std::result::Result<String, JsError> {
    let parsed = serde_json::from_str::<crate::dotk::Request>(request)
        .map_err(|_| JsError::new("invalid dot.k request"))?;
    json(crate::dotk::derive(&parsed))
}

#[wasm_bindgen(js_name = describeDotkMarket)]
pub fn describe_dotk_market_js(request: &str) -> std::result::Result<String, JsError> {
    let parsed = serde_json::from_str::<crate::dotk_market::DescribeRequest>(request)
        .map_err(|_| JsError::new("invalid dot.k marketplace descriptor request"))?;
    crate::dotk_market::describe(&parsed)
        .map(|value| value.to_string())
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareDotkMarket)]
pub fn prepare_dotk_market_js(request: &str) -> std::result::Result<String, JsError> {
    let parsed = serde_json::from_str::<crate::dotk_market::Request>(request)
        .map_err(|_| JsError::new("invalid dot.k marketplace transaction"))?;
    json(crate::dotk_market::prepare(&parsed))
}

#[wasm_bindgen(js_name = signDotkMarket)]
pub fn sign_dotk_market_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let parsed = serde_json::from_str::<crate::dotk_market::Request>(request)
        .map_err(|_| JsError::new("invalid dot.k marketplace transaction"))?;
    json(crate::dotk_market::sign(secret, &parsed, review_hash))
}

fn json<T: Serialize>(value: Result<T>) -> std::result::Result<String, JsError> {
    value
        .and_then(|item| serde_json::to_string(&item).map_err(|_| CoreError::Serialization))
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = generateWallet)]
pub fn generate_wallet_js(passphrase: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_passphrase =
        crate::secret_input::SecretInput::new(passphrase).map_err(JsError::new)?;
    let passphrase = owned_passphrase.text();
    json(generate_wallet_with_passphrase(passphrase))
}

#[wasm_bindgen(js_name = generateWalletWithWordCount)]
pub fn generate_wallet_with_word_count_js(
    passphrase: Vec<u8>,
    word_count: usize,
) -> std::result::Result<String, JsError> {
    let owned_passphrase =
        crate::secret_input::SecretInput::new(passphrase).map_err(JsError::new)?;
    let passphrase = owned_passphrase.text();
    json(generate_wallet_with_word_count(passphrase, word_count))
}

#[wasm_bindgen(js_name = importWallet)]
pub fn import_wallet_js(
    phrase: Vec<u8>,
    passphrase: Vec<u8>,
) -> std::result::Result<String, JsError> {
    let owned_phrase = crate::secret_input::SecretInput::new(phrase).map_err(JsError::new)?;
    let phrase = owned_phrase.text();
    let owned_passphrase =
        crate::secret_input::SecretInput::new(passphrase).map_err(JsError::new)?;
    let passphrase = owned_passphrase.text();
    json(import_wallet_with_passphrase(phrase, passphrase))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MnemonicWordStatus {
    invalid_words: Vec<String>,
    suggestions: Vec<String>,
}

#[wasm_bindgen(js_name = mnemonicWordStatus)]
pub fn mnemonic_word_status_js(phrase: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_phrase = crate::secret_input::SecretInput::new(phrase).map_err(JsError::new)?;
    let phrase = owned_phrase.text();
    let normalized = Zeroizing::new(phrase.to_ascii_lowercase());
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
pub fn import_private_key_js(value: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_value = crate::secret_input::SecretInput::new(value).map_err(JsError::new)?;
    let value = owned_value.text();
    json(import_private_key(value))
}

#[wasm_bindgen(js_name = prepareWyrmGenesis)]
pub fn prepare_wyrm_genesis_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str::<WyrmGenesisRequest>(request)
        .map_err(|_| JsError::new("invalid Covenant Wyrm genesis request"))?;
    json(prepare_wyrm_genesis(&request))
}

#[wasm_bindgen(js_name = signWyrmGenesis)]
pub fn sign_wyrm_genesis_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_str::<WyrmGenesisRequest>(request)
        .map_err(|_| JsError::new("invalid Covenant Wyrm genesis request"))?;
    json(sign_wyrm_genesis(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = prepareWyrmTransition)]
pub fn prepare_wyrm_transition_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str::<WyrmTransitionRequest>(request)
        .map_err(|_| JsError::new("invalid Covenant Wyrm transition request"))?;
    json(prepare_wyrm_transition(&request))
}

#[wasm_bindgen(js_name = signWyrmTransition)]
pub fn sign_wyrm_transition_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_str::<WyrmTransitionRequest>(request)
        .map_err(|_| JsError::new("invalid Covenant Wyrm transition request"))?;
    json(sign_wyrm_transition(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = deriveBackupKey)]
pub fn derive_backup_key_js(
    password: Vec<u8>,
    salt_hex: &str,
) -> std::result::Result<DerivedBackupKey, JsError> {
    let owned_password = crate::secret_input::SecretInput::new(password).map_err(JsError::new)?;
    let password = owned_password.text();
    let salt = hex::decode(salt_hex).map_err(|_| JsError::new("invalid backup salt"))?;
    derive_backup_key(password, &salt)
        .map(|key| DerivedBackupKey { key })
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = deriveBackupKeyV3)]
pub fn derive_backup_key_v3_js(
    password: Vec<u8>,
    salt_hex: &str,
) -> std::result::Result<DerivedBackupKey, JsError> {
    let owned_password = crate::secret_input::SecretInput::new(password).map_err(JsError::new)?;
    let password = owned_password.text();
    let salt = hex::decode(salt_hex).map_err(|_| JsError::new("invalid backup salt"))?;
    derive_backup_key_v3(password, &salt)
        .map(|key| DerivedBackupKey { key })
        .map_err(|error| JsError::new(&error.to_string()))
}

// The JS adapter copies these bytes directly from linear memory and immediately
// calls free(). The key remains owned by Zeroizing until then, including when
// JS throws while copying it. Never return a non-wiping Vec or a hex String.
#[wasm_bindgen]
pub struct DerivedBackupKey {
    key: Zeroizing<[u8; 32]>,
}

#[wasm_bindgen]
impl DerivedBackupKey {
    pub fn pointer(&self) -> usize {
        self.key.as_ptr() as usize
    }

    pub fn wipe(&mut self) {
        self.key.zeroize();
    }
}

#[wasm_bindgen(js_name = deriveAddressRange)]
pub fn derive_address_range_js(
    secret: Vec<u8>,
    coin_type: u32,
    account: u32,
    change: u32,
    start: u32,
    count: u32,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
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
pub fn derive_evm_address_js(secret: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    derive_evm_address(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = exportEvmPrivateKey)]
pub fn export_evm_private_key_js(secret: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    export_evm_private_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareEvmTransaction)]
pub fn prepare_evm_transaction_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid EVM request"))?;
    json(prepare_evm_transaction(&request))
}

#[wasm_bindgen(js_name = signEvmTransaction)]
pub fn sign_evm_transaction_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid EVM request"))?;
    json(sign_evm_transaction(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = exportPrivateKey)]
pub fn export_private_key_js(secret: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    export_private_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = publicKey)]
pub fn public_key_js(secret: Vec<u8>) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    public_key(secret).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareTransaction)]
pub fn prepare_transaction_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(prepare_transaction(&request))
}

#[wasm_bindgen(js_name = signTransaction)]
pub fn sign_transaction_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(sign_transaction(secret, &request, review_hash))
}

#[wasm_bindgen(js_name = signPersonalMessage)]
pub fn sign_personal_message_js(
    secret: Vec<u8>,
    address: &str,
    message: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    sign_personal_message(secret, address, message)
        .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = prepareNftMarket)]
pub fn prepare_nft_market_js(request: &str) -> std::result::Result<String, JsError> {
    crate::prepare_nft_market_json(request).map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = preparePskt)]
pub fn prepare_pskt_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid request"))?;
    json(prepare_pskt(&request))
}

#[wasm_bindgen(js_name = prepareKronTransfer)]
pub fn prepare_kron_transfer_js(request: &str) -> std::result::Result<String, JsError> {
    let request = serde_json::from_str(request).map_err(|_| JsError::new("invalid KCC20 request"))?;
    json(crate::prepare_kron_transfer(&request))
}

#[wasm_bindgen(js_name = signPskt)]
pub fn sign_pskt_js(
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
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
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
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
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
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
    secret: Vec<u8>,
    request: &str,
    review_hash: &str,
) -> std::result::Result<String, JsError> {
    let owned_secret = crate::secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    let secret = owned_secret.text();
    let request = serde_json::from_str(request)
        .map_err(|_| JsError::new("invalid policy transaction request"))?;
    json(sign_policy_transaction(secret, &request, review_hash))
}
