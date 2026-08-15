use crate::{
    derive_address_range, derive_backup_key, derive_evm_address, export_evm_private_key, export_private_key,
    generate_wallet_with_passphrase, import_private_key, import_wallet_with_passphrase,
    prepare_evm_transaction, prepare_inscription, prepare_kcc20_transfer, prepare_kron_transfer,
    prepare_policy_transaction, prepare_pskt, prepare_reveal, prepare_transaction,
    sign_evm_transaction, sign_kcc20_transfer, sign_personal_message, sign_policy_transaction,
    sign_pskt, sign_reveal, sign_transaction, EvmTransactionRequest, InscriptionRequest,
    Kcc20TransferRequest, KronTransferRequest, PolicyTransactionRequest, PsktRequest,
    RevealRequest, SendRequest,
};

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareKronTransfer(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<KronTransferRequest>(&raw)
                .map_err(|_| "invalid KRON transfer request".to_string())
        })
        .and_then(|request| prepare_kron_transfer(&request).map_err(|error| error.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_preparePskt(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<PsktRequest>(&raw)
                .map_err(|_| "invalid PSKT request".to_string())
        })
        .and_then(|request| prepare_pskt(&request).map_err(|e| e.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signPskt(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let request_json = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request: PsktRequest =
            serde_json::from_str(&request_json).map_err(|_| "invalid PSKT request".to_string())?;
        let signed = sign_pskt(&secret, &request, &review_hash).map_err(|e| e.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}
use jni::{
    objects::{JClass, JString},
    sys::jstring,
    JNIEnv,
};
use serde_json::json;
use zeroize::Zeroizing;

fn output(env: &mut JNIEnv, value: String) -> jstring {
    let value = Zeroizing::new(value);
    env.new_string(value.as_str())
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_deriveEvmAddress(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
) -> jstring {
    let result = read(&mut env, &secret)
        .and_then(|secret| derive_evm_address(&secret).map_err(|error| error.to_string()))
        .map(|address| {
            json!({"address": address, "derivationPath": "m/44'/60'/0'/0/0"}).to_string()
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_exportEvmPrivateKey(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
) -> jstring {
    let result = read(&mut env, &secret)
        .and_then(|secret| export_evm_private_key(&secret).map_err(|error| error.to_string()))
        .map(|private_key| json!({"privateKey": private_key}).to_string());
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareEvmTransaction(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<EvmTransactionRequest>(&raw)
                .map_err(|_| "invalid EVM transaction request".to_string())
        })
        .and_then(|request| prepare_evm_transaction(&request).map_err(|error| error.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signEvmTransaction(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let raw = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request = serde_json::from_str::<EvmTransactionRequest>(&raw)
            .map_err(|_| "invalid EVM transaction request".to_string())?;
        let signed = sign_evm_transaction(&secret, &request, &review_hash)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_preparePolicyTransaction(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<PolicyTransactionRequest>(&raw)
                .map_err(|_| "invalid policy transaction request".to_string())
        })
        .and_then(|request| prepare_policy_transaction(&request).map_err(|e| e.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signPolicyTransaction(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let request_json = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request: PolicyTransactionRequest = serde_json::from_str(&request_json)
            .map_err(|_| "invalid policy transaction request".to_string())?;
        let signed =
            sign_policy_transaction(&secret, &request, &review_hash).map_err(|e| e.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareInscription(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<InscriptionRequest>(&raw)
                .map_err(|_| "invalid inscription request".to_string())
        })
        .and_then(|request| prepare_inscription(&request).map_err(|e| e.to_string()))
        .and_then(|plan| {
            serde_json::to_string(&plan).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareReveal(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<RevealRequest>(&raw)
                .map_err(|_| "invalid reveal request".to_string())
        })
        .and_then(|request| prepare_reveal(&request).map_err(|e| e.to_string()))
        .and_then(|plan| {
            serde_json::to_string(&plan).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signReveal(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let raw = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request: RevealRequest =
            serde_json::from_str(&raw).map_err(|_| "invalid reveal request".to_string())?;
        let signed = sign_reveal(&secret, &request, &review_hash).map_err(|e| e.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

fn error_json(error: impl std::fmt::Display) -> String {
    json!({"error": error.to_string()}).to_string()
}

fn read(env: &mut JNIEnv, value: &JString) -> std::result::Result<Zeroizing<String>, String> {
    env.get_string(value)
        .map(|s| Zeroizing::new(s.into()))
        .map_err(|_| "invalid JNI string".to_string())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_generateWallet(
    mut env: JNIEnv,
    _class: JClass,
    passphrase: JString,
) -> jstring {
    let result = read(&mut env, &passphrase)
        .map_err(error_json)
        .and_then(|passphrase| {
            generate_wallet_with_passphrase(&passphrase)
                .and_then(|wallet| {
                    serde_json::to_string(&wallet).map_err(|_| crate::CoreError::Serialization)
                })
                .map_err(error_json)
        });
    output(&mut env, result.unwrap_or_else(|error| error))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_importWallet(
    mut env: JNIEnv,
    _class: JClass,
    phrase: JString,
    passphrase: JString,
) -> jstring {
    let result = (|| {
        let phrase = read(&mut env, &phrase)?;
        let passphrase = read(&mut env, &passphrase)?;
        import_wallet_with_passphrase(&phrase, &passphrase)
            .and_then(|wallet| {
                serde_json::to_string(&wallet).map_err(|_| crate::CoreError::Serialization)
            })
            .map_err(|error| error_json(error))
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_importPrivateKey(
    mut env: JNIEnv,
    _class: JClass,
    private_key: JString,
) -> jstring {
    let result = read(&mut env, &private_key)
        .map_err(error_json)
        .and_then(|private_key| {
            import_private_key(&private_key)
                .and_then(|wallet| {
                    serde_json::to_string(&wallet).map_err(|_| crate::CoreError::Serialization)
                })
                .map_err(error_json)
        });
    output(&mut env, result.unwrap_or_else(|error| error))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_exportPrivateKey(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
) -> jstring {
    let result = read(&mut env, &secret).and_then(|secret| {
        export_private_key(&secret)
            .map(|private_key| json!({"privateKey": private_key}).to_string())
            .map_err(|error| error.to_string())
    });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_deriveAddresses(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    coin_type: i32,
    account: i32,
    change: i32,
    start: i32,
    count: i32,
) -> jstring {
    let result = read(&mut env, &secret).and_then(|secret| {
        let values = [coin_type, account, change, start, count];
        if values.iter().any(|value| *value < 0) {
            return Err("invalid HD discovery range".to_string());
        }
        derive_address_range(
            &secret,
            coin_type as u32,
            account as u32,
            change as u32,
            start as u32,
            count as u32,
        )
        .and_then(|addresses| {
            serde_json::to_string(&addresses).map_err(|_| crate::CoreError::Serialization)
        })
        .map_err(|error| error.to_string())
    });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_deriveBackupKey(
    mut env: JNIEnv,
    _class: JClass,
    password: JString,
    salt_hex: JString,
) -> jstring {
    let result = (|| {
        let password = read(&mut env, &password)?;
        let salt_hex = read(&mut env, &salt_hex)?;
        let salt = hex::decode(salt_hex).map_err(|_| "invalid backup salt".to_string())?;
        derive_backup_key(&password, &salt)
            .map(|key| hex::encode(key.as_slice()))
            .map_err(|error| error.to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareTransaction(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<SendRequest>(&raw).map_err(|_| "invalid request".to_string())
        })
        .and_then(|request| prepare_transaction(&request).map_err(|e| e.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signTransaction(
    mut env: JNIEnv,
    _class: JClass,
    phrase: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let phrase = read(&mut env, &phrase)?;
        let request_json = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request: SendRequest =
            serde_json::from_str(&request_json).map_err(|_| "invalid request".to_string())?;
        let signed =
            sign_transaction(&phrase, &request, &review_hash).map_err(|e| e.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_prepareKcc20Transfer(
    mut env: JNIEnv,
    _class: JClass,
    request_json: JString,
) -> jstring {
    let result = read(&mut env, &request_json)
        .and_then(|raw| {
            serde_json::from_str::<Kcc20TransferRequest>(&raw)
                .map_err(|_| "invalid KCC20 transfer request".to_string())
        })
        .and_then(|request| prepare_kcc20_transfer(&request).map_err(|e| e.to_string()))
        .and_then(|prepared| {
            serde_json::to_string(&prepared).map_err(|_| "serialization failed".to_string())
        });
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signKcc20Transfer(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    request_json: JString,
    review_hash: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let request_json = read(&mut env, &request_json)?;
        let review_hash = read(&mut env, &review_hash)?;
        let request: Kcc20TransferRequest = serde_json::from_str(&request_json)
            .map_err(|_| "invalid KCC20 transfer request".to_string())?;
        let signed =
            sign_kcc20_transfer(&secret, &request, &review_hash).map_err(|e| e.to_string())?;
        serde_json::to_string(&signed).map_err(|_| "serialization failed".to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_space_kasvault_wallet_SecureCore_signPersonalMessage(
    mut env: JNIEnv,
    _class: JClass,
    secret: JString,
    address: JString,
    message: JString,
) -> jstring {
    let result = (|| {
        let secret = read(&mut env, &secret)?;
        let address = read(&mut env, &address)?;
        let message = read(&mut env, &message)?;
        sign_personal_message(&secret, &address, &message)
            .map(|signature| json!({"signature": signature}).to_string())
            .map_err(|error| error.to_string())
    })();
    output(&mut env, result.unwrap_or_else(error_json))
}
