//! Windows host adapter. No private material is returned to Flutter. Android
//! and WASM do not compile this module. The reviewed signing engines are shared.
use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use zeroize::{Zeroize, Zeroizing};
type R<T> = std::result::Result<T, String>;
#[path = "desktop_update.rs"]
mod updates;
type Prompt = unsafe extern "C" fn(u32, *const c_char, *const c_char) -> *mut c_char;
type PromptFree = unsafe extern "C" fn(*mut c_char);
struct Host {
    prompt: Prompt,
    free: PromptFree,
    directory: PathBuf,
    cancellation: u64,
}
static CANCELLATION: AtomicU64 = AtomicU64::new(0);
static FORGET_AUTH: AtomicBool = AtomicBool::new(false);
impl Host {
    fn ask(&self, mode: u32, title: &str, text: &str) -> R<Zeroizing<String>> {
        let title = CString::new(title).map_err(|_| "Invalid dialog title")?;
        let text = CString::new(text).map_err(|_| "Invalid dialog content")?;
        let p = unsafe { (self.prompt)(mode, title.as_ptr(), text.as_ptr()) };
        let mut dialog_text = text.into_bytes_with_nul();
        dialog_text.zeroize();
        if p.is_null() {
            return Err("Cancelled. No new transaction was signed.".into());
        }
        let answer_bytes = Zeroizing::new(unsafe { CStr::from_ptr(p) }.to_bytes().to_vec());
        unsafe { (self.free)(p) };
        if CANCELLATION.load(Ordering::SeqCst) != self.cancellation {
            return Err(
                "Wallet locked while approval was open. Review again; no transaction was signed."
                    .into(),
            );
        }
        Ok(Zeroizing::new(
            std::str::from_utf8(&answer_bytes)
                .map_err(|_| "Invalid dialog response")?
                .to_owned(),
        ))
    }
    fn info(&self, title: &str, text: &str) -> R<()> {
        self.ask(6, title, text).map(|_| ())
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vault {
    active: String,
    wallets: Vec<Wallet>,
    pin_salt: String,
    pin_hash: String,
    #[serde(default)]
    failures: u32,
    #[serde(default)]
    retry_after: u64,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Wallet {
    id: String,
    name: String,
    address: String,
    kind: String,
    protected_secret: String,
    addresses: Vec<Value>,
    #[serde(default)]
    covenant_vaults: Vec<Value>,
}
struct Token {
    operation: String,
    binding: String,
    wallet: String,
    generation: u64,
    expires: u64,
}
struct Review {
    operation: String,
    wallet: String,
    generation: u64,
    expires: u64,
    in_app: bool,
    review: Value,
}
#[derive(Default)]
struct Session {
    generation: u64,
    cancellation: u64,
    until: u64,
    nexus: bool,
    tokens: HashMap<String, Token>,
    reviews: HashMap<String, Review>,
}
static SESSION: OnceLock<Mutex<Session>> = OnceLock::new();
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn random<const N: usize>() -> R<[u8; N]> {
    let mut b = [0u8; N];
    getrandom::getrandom(&mut b).map_err(|_| "Random generator unavailable")?;
    Ok(b)
}
fn id() -> R<String> {
    Ok(hex::encode(random::<32>()?))
}
fn text<'a>(v: &'a Value, k: &str) -> R<&'a str> {
    v[k].as_str().ok_or_else(|| format!("Missing {k}"))
}
fn raw<'a>(a: &'a Value) -> R<&'a str> {
    let r = text(a, "request")?;
    if r.len() > 2 * 1024 * 1024 {
        return Err("Request too large".into());
    }
    Ok(r)
}
fn parse<T: serde::de::DeserializeOwned>(s: &str) -> R<T> {
    serde_json::from_str(s).map_err(|_| "Invalid native request".into())
}
fn encoded<T: Serialize>(v: T) -> R<Value> {
    Ok(Value::String(
        serde_json::to_string(&v).map_err(|_| "Cannot encode native result")?,
    ))
}
fn error<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}
fn wipe_json(v: &mut Value) {
    match v {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(wipe_json),
        Value::Object(o) => o.values_mut().for_each(wipe_json),
        _ => {}
    }
}

#[cfg(target_os = "windows")]
fn protect(input: &[u8], encrypt: bool) -> R<Zeroizing<Vec<u8>>> {
    #[repr(C)]
    struct Blob {
        len: u32,
        data: *mut u8,
    }
    #[link(name = "Crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            a: *const Blob,
            b: *const u16,
            c: *const Blob,
            d: *mut std::ffi::c_void,
            e: *mut std::ffi::c_void,
            f: u32,
            g: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            a: *const Blob,
            b: *mut *mut u16,
            c: *const Blob,
            d: *mut std::ffi::c_void,
            e: *mut std::ffi::c_void,
            f: u32,
            g: *mut Blob,
        ) -> i32;
    }
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn LocalFree(p: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    }
    if input.is_empty() || input.len() > 16 * 1024 * 1024 {
        return Err("Invalid protected vault length".into());
    }
    let a = Blob {
        len: input.len() as u32,
        data: input.as_ptr() as *mut u8,
    };
    let mut out = Blob {
        len: 0,
        data: std::ptr::null_mut(),
    };
    let success = unsafe {
        if encrypt {
            CryptProtectData(
                &a,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut out,
            )
        } else {
            CryptUnprotectData(
                &a,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut out,
            )
        }
    };
    if success == 0 {
        return Err("Windows could not unlock this encrypted vault. Use your original Windows account or restore an encrypted backup.".into());
    }
    let bytes = unsafe { std::slice::from_raw_parts_mut(out.data, out.len as usize) };
    let result = Zeroizing::new(bytes.to_vec());
    bytes.zeroize();
    unsafe { LocalFree(out.data.cast()) };
    Ok(result)
}
#[cfg(not(target_os = "windows"))]
fn protect(_input: &[u8], _encrypt: bool) -> R<Zeroizing<Vec<u8>>> {
    Err("Native wallet storage requires Windows DPAPI".into())
}
fn load(h: &Host) -> R<Vault> {
    let path = h.directory.join("wallets.dpapi");
    if !path.exists() {
        return Ok(Vault::default());
    }
    let bytes = std::fs::read(path).map_err(|_| "Cannot read encrypted wallet store")?;
    let clear = protect(&bytes, false)?;
    serde_json::from_slice(&clear).map_err(|_| "Encrypted wallet metadata is damaged".into())
}
fn save(h: &Host, v: &Vault) -> R<()> {
    use std::io::Write;
    std::fs::create_dir_all(&h.directory)
        .map_err(|_| "Cannot create the Windows wallet directory")?;
    let clear = Zeroizing::new(serde_json::to_vec(v).map_err(|_| "Cannot encode wallet metadata")?);
    let cipher = protect(&clear, true)?;
    let path = h.directory.join(format!("wallets-{}.tmp", id()?));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|_| "Cannot save encrypted wallet")?;
    file.write_all(&cipher)
        .and_then(|_| file.sync_all())
        .map_err(|_| "Cannot persist encrypted wallet")?;
    drop(file);
    std::fs::rename(path, h.directory.join("wallets.dpapi"))
        .map_err(|_| "Cannot atomically replace encrypted wallet")?;
    Ok(())
}
fn wallet<'a>(v: &'a Vault) -> R<&'a Wallet> {
    v.wallets
        .iter()
        .find(|w| w.id == v.active)
        .ok_or_else(|| "Select a signing wallet first".into())
}
fn root_secret(w: &Wallet) -> R<Zeroizing<String>> {
    let cipher = B64
        .decode(&w.protected_secret)
        .map_err(|_| "Invalid encrypted wallet")?;
    let clear = protect(&cipher, false)?;
    Ok(Zeroizing::new(
        std::str::from_utf8(&clear)
            .map_err(|_| "Invalid wallet secret")?
            .to_owned(),
    ))
}
fn signing_secret(w: &Wallet, address: &str, aggregate: bool) -> R<Zeroizing<String>> {
    let root = root_secret(w)?;
    let main = crate::address_with_prefix(address, false).map_err(error)?;
    let row = w
        .addresses
        .iter()
        .find(|a| a["address"] == main)
        .ok_or_else(|| "This address does not belong to the selected wallet".to_string())?;
    let path = text(row, "derivationPath")?;
    if aggregate || path == "private-key" {
        return Ok(root);
    }
    Ok(Zeroizing::new(format!("hd-path:{path}:{}", root.as_str())))
}
fn invalidate(s: &mut Session) {
    s.generation += 1;
    s.tokens.clear();
    s.reviews.clear();
    s.until = 0;
    s.nexus = false;
}
// Changing wallets revokes every signing review/token, but retains only the
// original, still-live global PIN login. This never extends or revives expiry.
fn switch_wallet_session(s: &mut Session) {
    let until = s.until;
    invalidate(s);
    if until > now() {
        s.until = until;
    }
}
fn unlock_minutes(a: &Value) -> u64 {
    let minutes = a["sessionMinutes"].as_u64().unwrap_or(5);
    if minutes == 0 {
        60
    } else {
        minutes.clamp(1, 60)
    }
}
fn refresh_unlock(s: &mut Session, a: &Value) -> bool {
    if !s.nexus || s.until <= now() {
        return false;
    }
    s.until = now() + unlock_minutes(a) * 60000;
    true
}
fn verify_pin(h: &Host, v: &mut Vault, s: &mut Session) -> R<bool> {
    if v.retry_after > now() {
        return Err("Too many incorrect PIN attempts. Please wait before trying again.".into());
    }
    if v.pin_hash.is_empty() {
        configure_pin(h, v)?;
        s.until = now() + 5 * 60000;
        return Ok(true);
    }
    let pin = h.ask(1, "Unlock Kaspire", "Enter your Kaspire PIN.")?;
    let salt = hex::decode(&v.pin_salt).map_err(|_| "PIN data damaged")?;
    let password = Zeroizing::new(format!("Kaspire Windows PIN:{}", pin.as_str()));
    let key = crate::derive_backup_key_v3_bytes(password.as_bytes(), &salt).map_err(error)?;
    let actual = hex::decode(&v.pin_hash).map_err(|_| "PIN data damaged")?;
    let matches = actual.len() == key.len()
        && actual
            .iter()
            .zip(key.iter())
            .fold(0u8, |a, (x, y)| a | (x ^ y))
            == 0;
    if !matches {
        v.failures = v.failures.saturating_add(1);
        if v.failures >= 5 {
            v.retry_after = now() + 60000;
        }
        save(h, v)?;
        return Err("Incorrect Kaspire PIN. No transaction was signed.".into());
    }
    v.failures = 0;
    v.retry_after = 0;
    save(h, v)?;
    s.until = now() + 5 * 60000;
    Ok(true)
}
fn configure_pin(h: &Host, v: &mut Vault) -> R<()> {
    let one = h.ask(
        1,
        "Set Kaspire PIN",
        "Choose a Kaspire PIN with 6–32 digits. It is required to unlock the Windows wallet.",
    )?;
    if one.len() < 6 || one.len() > 32 || !one.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Use 6–32 digits for the PIN".into());
    }
    let two = h.ask(1, "Confirm Kaspire PIN", "Enter the same PIN again.")?;
    if *one != *two {
        return Err("PINs do not match".into());
    }
    let salt = random::<32>()?;
    let password = Zeroizing::new(format!("Kaspire Windows PIN:{}", one.as_str()));
    let hash = crate::derive_backup_key_v3_bytes(password.as_bytes(), &salt).map_err(error)?;
    v.pin_salt = hex::encode(salt);
    v.pin_hash = hex::encode(hash.as_slice());
    v.failures = 0;
    v.retry_after = 0;
    save(h, v)
}
fn store_wallet(h: &Host, v: &mut Vault, secret: &str, address: &str, name: &str) -> R<()> {
    if v.wallets.iter().any(|w| w.address == address) {
        return Err("This wallet is already imported".into());
    }
    let kind = if secret.starts_with("private:") {
        "private-key"
    } else {
        "mnemonic"
    };
    let addresses =
        crate::derive_address_range(secret, crate::MODERN_COIN_TYPE, 0, 0, 0, 1).map_err(error)?;
    let w = Wallet {
        id: id()?,
        name: name.into(),
        address: address.into(),
        kind: kind.into(),
        protected_secret: B64.encode(protect(secret.as_bytes(), true)?.as_slice()),
        covenant_vaults: Vec::new(),
        addresses: addresses
            .iter()
            .map(|a| serde_json::to_value(a).unwrap())
            .collect(),
    };
    v.active = w.id.clone();
    v.wallets.push(w);
    save(h, v)
}
fn mnemonic_secret(mnemonic: &str, passphrase: &str) -> Zeroizing<String> {
    Zeroizing::new(if passphrase.is_empty() {
        format!("mnemonic:{mnemonic}")
    } else {
        format!("mnemonic-passphrase:{}:{mnemonic}", hex::encode(passphrase))
    })
}
fn json_secret_address(secret: &str) -> R<String> {
    if let Some(key) = secret.strip_prefix("private:") {
        return Ok(crate::import_private_key(key)
            .map_err(error)?
            .address
            .clone());
    }
    if let Some(phrase) = secret.strip_prefix("mnemonic:") {
        return Ok(crate::import_wallet(phrase).map_err(error)?.address.clone());
    }
    if let Some(value) = secret.strip_prefix("mnemonic-passphrase:") {
        let (p, m) = value.split_once(':').ok_or("Invalid passphrase backup")?;
        let p = Zeroizing::new(hex::decode(p).map_err(|_| "Invalid backup passphrase")?);
        return Ok(crate::import_wallet_with_passphrase(
            m,
            std::str::from_utf8(&p).map_err(|_| "Invalid backup passphrase")?,
        )
        .map_err(error)?
        .address
        .clone());
    }
    Err("Unknown backup wallet format".into())
}

fn core_prepare(method: &str, a: &Value) -> R<(Value, &'static str)> {
    macro_rules! p {
        ($t:ty,$f:path,$operation:expr) => {{
            let req: $t = parse(raw(a)?)?;
            (
                serde_json::to_value($f(&req).map_err(error)?).map_err(error)?,
                $operation,
            )
        }};
    }
    Ok(match method {
        "prepareTransaction" | "prepareKaspacomCommit" => p!(
            crate::SendRequest,
            crate::prepare_transaction,
            "signTransaction"
        ),
        "prepareReveal" | "prepareKaspacomReveal" => {
            p!(crate::RevealRequest, crate::prepare_reveal, "signReveal")
        }
        "preparePskt" | "prepareKaspacomPskt" => {
            p!(crate::PsktRequest, crate::prepare_pskt, "signPskt")
        }
        "prepareKcc20Transfer" => p!(
            crate::Kcc20TransferRequest,
            crate::prepare_kcc20_transfer,
            "signKcc20Transfer"
        ),
        "prepareEvmTransaction" => p!(
            crate::EvmTransactionRequest,
            crate::prepare_evm_transaction,
            "signEvmTransaction"
        ),
        "preparePolicyTransaction" => p!(
            crate::PolicyTransactionRequest,
            crate::prepare_policy_transaction,
            "signPolicyTransaction"
        ),
        "prepareWyrmGenesis" => p!(
            crate::WyrmGenesisRequest,
            crate::prepare_wyrm_genesis,
            "signWyrmGenesis"
        ),
        "prepareWyrmTransition" => p!(
            crate::WyrmTransitionRequest,
            crate::prepare_wyrm_transition,
            "signWyrmTransition"
        ),
        "prepareDotkMarket" => p!(
            crate::dotk_market::Request,
            crate::dotk_market::prepare,
            "signDotkMarket"
        ),
        "prepareCovenantVault" => p!(
            crate::covenant_vault::Request,
            crate::covenant_vault::prepare,
            "signCovenantVault"
        ),
        _ => return Err("Unknown native review method".into()),
    })
}
fn core_sign(method: &str, a: &Value, secret: &str) -> R<Value> {
    let hash = text(a, "reviewHash")?;
    macro_rules! p {
        ($t:ty,$f:path) => {{
            let req: $t = parse(raw(a)?)?;
            encoded($f(secret, &req, hash).map_err(error)?)
        }};
    }
    match method {
        "signTransaction" => p!(crate::SendRequest, crate::sign_transaction),
        "signReveal" => p!(crate::RevealRequest, crate::sign_reveal),
        "signPskt" => p!(crate::PsktRequest, crate::sign_pskt),
        "signKcc20Transfer" => p!(crate::Kcc20TransferRequest, crate::sign_kcc20_transfer),
        "signEvmTransaction" => p!(crate::EvmTransactionRequest, crate::sign_evm_transaction),
        "signPolicyTransaction" => p!(
            crate::PolicyTransactionRequest,
            crate::sign_policy_transaction
        ),
        "signWyrmGenesis" => p!(crate::WyrmGenesisRequest, crate::sign_wyrm_genesis),
        "signWyrmTransition" => p!(crate::WyrmTransitionRequest, crate::sign_wyrm_transition),
        "signDotkMarket" => p!(crate::dotk_market::Request, crate::dotk_market::sign),
        "signCovenantVault" => p!(crate::covenant_vault::Request, crate::covenant_vault::sign),
        _ => Err("Unknown native signing method".into()),
    }
}
fn native_binding(a: &Value) -> R<String> {
    if a.get("reviewHash").is_some() {
        return Ok(text(a, "reviewHash")?.into());
    }
    Ok(format!("{}\0{}", text(a, "address")?, text(a, "message")?))
}
fn consume(s: &mut Session, v: &Vault, a: &Value, operation: &str, binding: &str) -> R<()> {
    let token = s
        .tokens
        .remove(text(a, "authorizationToken")?)
        .ok_or("Authorization expired. Unlock and review again.")?;
    if token.operation != operation
        || token.binding != binding
        || token.wallet != v.active
        || token.generation != s.generation
        || token.expires < now()
    {
        return Err("Wallet or reviewed terms changed. No transaction was signed.".into());
    }
    Ok(())
}
fn valid_nexus(binding: &str) -> bool {
    let Some((address, message)) = binding.split_once('\0') else {
        return false;
    };
    let l: Vec<_> = message.split('\n').collect();
    if l.len() != 11
        || l[0] != "Kaspire Internal NFT Offers"
        || l[1] != ""
        || l[2] != "Domain: kaspire.kaslab.space"
        || l[3] != "Purpose: internal-private-offers-v1"
        || l[4] != format!("Wallet: {address}")
        || !l[5].starts_with("Nonce: ")
        || l[5].len() != 50
        || !l[5][7..]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        || l[8] != ""
        || l[9]
            != "Authenticate this wallet for private offers and notifications inside Kaspire only."
        || l[10] != "This signature does not create a transaction or spend funds."
    {
        return false;
    }
    let (Some(i), Some(e)) = (
        l[6].strip_prefix("Issued at: "),
        l[7].strip_prefix("Expires at: "),
    ) else {
        return false;
    };
    let (Ok(i), Ok(e)) = (
        chrono::DateTime::parse_from_rfc3339(i),
        chrono::DateTime::parse_from_rfc3339(e),
    ) else {
        return false;
    };
    let lifetime = e.timestamp_millis() - i.timestamp_millis();
    lifetime > 0
        && lifetime <= 360000
        && e.timestamp_millis() > now() as i64
        && i.timestamp_millis() <= now() as i64 + 30000
}

fn validate_vault_catalog(catalog: &[Value]) -> R<()> {
    if catalog.len() > 2000 {
        return Err("Too many vault records".into());
    }
    let mut seen = std::collections::HashSet::new();
    for item in catalog {
        let fields = item.as_object().ok_or("Invalid vault journal entry")?;
        if fields
            .keys()
            .any(|k| !matches!(k.as_str(), "record" | "pending"))
        {
            return Err("Unsupported vault journal field".into());
        }
        let record =
            crate::vault_recovery::validate_record(&item["record"].to_string()).map_err(error)?;
        if !seen.insert(text(&record, "covenantId")?.to_owned()) {
            return Err("Duplicate vault identity".into());
        }
        if let Some(pending) = item.get("pending").filter(|p| !p.is_null()) {
            let fields = pending
                .as_object()
                .ok_or("Invalid pending vault transaction")?;
            if fields.keys().any(|k| {
                !matches!(
                    k.as_str(),
                    "transactionId" | "wrpcJson" | "submitJson" | "action" | "submitted"
                )
            }) || !matches!(
                text(pending, "action")?,
                "create" | "heartbeat" | "release" | "claim"
            ) || text(pending, "transactionId")?.len() != 64
                || hex::decode(text(pending, "transactionId")?).is_err()
                || text(pending, "wrpcJson")?.len() > 512 * 1024
                || pending.get("submitted").is_some_and(|s| !s.is_boolean())
            {
                return Err("Invalid pending vault transaction journal".into());
            }
        }
    }
    Ok(())
}
fn backup(h: &Host, v: &Vault) -> R<Value> {
    let w = wallet(v)?;
    let secret = root_secret(w)?;
    let password = h.ask(
        1,
        "Encrypted backup",
        "Choose a backup password with at least 12 characters.",
    )?;
    let repeat = h.ask(
        1,
        "Confirm backup password",
        "Enter the same backup password again.",
    )?;
    if *password != *repeat {
        return Err("Backup passwords do not match".into());
    }
    let salt = random::<32>()?;
    let iv = random::<12>()?;
    let key = crate::derive_backup_key_v3_bytes(password.as_bytes(), &salt).map_err(error)?;
    let mut payload = json!({"secret":secret.as_str(),"address":w.address,"addresses":w.addresses,"covenantVaults":w.covenant_vaults,"createdAt":now()});
    let clear = Zeroizing::new(serde_json::to_vec(&payload).map_err(error)?);
    wipe_json(&mut payload);
    let cipher = Aes256Gcm::new_from_slice(key.as_slice())
        .map_err(|_| "Invalid backup key")?
        .encrypt(Nonce::from_slice(&iv), clear.as_slice())
        .map_err(|_| "Cannot encrypt backup")?;
    let envelope = json!({"format":"kaspire-backup-v3","kdf":"argon2id-v19","memoryKiB":65536,"iterations":4,"parallelism":1,"address":w.address,"salt":B64.encode(salt),"iv":B64.encode(iv),"ciphertext":B64.encode(cipher)});
    let path = h.ask(5, "Save encrypted Kaspire backup", "Kaspire-Backup.json")?;
    std::fs::write(Path::new(path.as_str()), envelope.to_string())
        .map_err(|_| "Cannot write backup file")?;
    Ok(Value::String(format!(
        "Encrypted backup saved to {}",
        path.as_str()
    )))
}
fn restore(h: &Host, v: &mut Vault) -> R<Value> {
    let path = h.ask(4, "Choose a Kaspire backup", "JSON backup files")?;
    let meta = std::fs::metadata(path.as_str()).map_err(|_| "Cannot open backup")?;
    if meta.len() > 8 * 1024 * 1024 {
        return Err("Backup too large".into());
    }
    let data: Value =
        parse(&std::fs::read_to_string(path.as_str()).map_err(|_| "Cannot read backup")?)?;
    let version = match data["format"].as_str() {
        Some("kaspire-backup-v3") => 3,
        Some("kaspire-backup-v2") => 2,
        _ => {
            return Err(
                "Restore an Argon2id v2/v3 Kaspire backup, or import the recovery phrase.".into(),
            )
        }
    };
    if data["kdf"] != "argon2id-v19"
        || data["parallelism"] != 1
        || data["memoryKiB"] != if version == 3 { 65536 } else { 32768 }
        || data["iterations"] != if version == 3 { 4 } else { 3 }
    {
        return Err("Unsupported backup KDF parameters".into());
    }
    let password = h.ask(
        1,
        "Restore encrypted backup",
        "Enter the password for this backup.",
    )?;
    let salt = B64
        .decode(text(&data, "salt")?)
        .map_err(|_| "Invalid backup salt")?;
    let iv = B64
        .decode(text(&data, "iv")?)
        .map_err(|_| "Invalid backup IV")?;
    if iv.len() != 12 {
        return Err("Invalid backup IV length".into());
    }
    let cipher = B64
        .decode(text(&data, "ciphertext")?)
        .map_err(|_| "Invalid backup ciphertext")?;
    let key = if version == 3 {
        crate::derive_backup_key_v3_bytes(password.as_bytes(), &salt)
    } else {
        crate::derive_backup_key_bytes(password.as_bytes(), &salt)
    }
    .map_err(error)?;
    let clear = Zeroizing::new(
        Aes256Gcm::new_from_slice(key.as_slice())
            .map_err(|_| "Invalid backup key")?
            .decrypt(Nonce::from_slice(&iv), cipher.as_slice())
            .map_err(|_| "Wrong password or damaged backup")?,
    );
    let mut payload: Value =
        serde_json::from_slice(&clear).map_err(|_| "Damaged backup contents")?;
    let secret = match payload["secret"].take() {
        Value::String(s) => Zeroizing::new(s),
        _ => return Err("Backup has no signing wallet".into()),
    };
    let address = json_secret_address(&secret)?;
    if payload["address"] != address {
        return Err("Backup address verification failed".into());
    }
    // Never silently discard recovery state for an unsupported address profile.
    if payload["hiddenKas"].as_object().is_some_and(|o| {
        o.get("receiveCount").and_then(Value::as_u64).unwrap_or(0) > 0
            || o.get("changeCount").and_then(Value::as_u64).unwrap_or(0) > 0
            || o.get("pending").is_some_and(|v| !v.is_null())
            || o.get("exposed")
                .and_then(Value::as_array)
                .is_some_and(|a| !a.is_empty())
    }) {
        return Err("This backup contains P2SH recovery data not supported by this Windows version. Restore it in Android; no recovery data has been discarded.".into());
    }
    let catalog = payload["covenantVaults"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    validate_vault_catalog(&catalog)?;
    let rows = payload["addresses"].as_array().cloned().unwrap_or_default();
    let checked = verify_addresses(&secret, &rows)?;
    store_wallet(h, v, &secret, &address, "Restored Wallet")?;
    let w = v.wallets.iter_mut().find(|w| w.id == v.active).unwrap();
    w.covenant_vaults = catalog;
    for row in checked {
        if !w.addresses.iter().any(|r| r["address"] == row["address"]) {
            w.addresses.push(row)
        }
    }
    save(h, v)?;
    Ok(Value::String(address))
}
fn verify_addresses(secret: &str, rows: &[Value]) -> R<Vec<Value>> {
    if rows.len() > 10000 {
        return Err("Too many HD addresses".into());
    }
    for row in rows {
        let coin = u32::try_from(row["coinType"].as_u64().ok_or("Missing coin type")?)
            .map_err(|_| "Invalid coin type")?;
        let account =
            u32::try_from(row["account"].as_u64().unwrap_or(0)).map_err(|_| "Invalid account")?;
        let branch = u32::try_from(row["change"].as_u64().ok_or("Missing branch")?)
            .map_err(|_| "Invalid branch")?;
        let index = u32::try_from(row["index"].as_u64().ok_or("Missing index")?)
            .map_err(|_| "Invalid address index")?;
        let expected =
            crate::derive_address_range(secret, coin, account, branch, index, 1).map_err(error)?;
        if expected.len() != 1
            || row["address"] != expected[0].address
            || row["derivationPath"] != expected[0].derivation_path
        {
            return Err("An HD path/address does not match the encrypted wallet".into());
        }
    }
    Ok(rows.to_vec())
}

fn dispatch(h: &Host, method: &str, a: &Value, v: &mut Vault, s: &mut Session) -> R<Value> {
    if method.starts_with("prepare")
        && !matches!(
            method,
            "prepareInscription"
                | "prepareKronTransfer"
                | "prepareNftMarket"
                | "prepareKaspacomMarket"
                | "prepareHiddenKas"
                | "prepareTangemCommit"
                | "prepareTangemReveal"
        )
    {
        let (review, operation) = core_prepare(method, a)?;
        let hash = text(&review, "reviewHash")?.to_owned();
        s.reviews.retain(|_, r| r.expires > now());
        if s.reviews.len() > 100 {
            s.reviews.clear()
        }
        let in_app = match method {
            "prepareKaspacomCommit" => {
                let operation: crate::InscriptionRequest = parse(text(a, "operation")?)?;
                let payment: crate::SendRequest = parse(raw(a)?)?;
                let plan = crate::prepare_inscription(&operation).map_err(error)?;
                matches!(
                    operation.kind.as_str(),
                    "krc20-list" | "krc721-list" | "kns-list"
                ) && operation.sender == operation.recipient
                    && payment.sender == operation.sender
                    && payment.recipient == plan.commit_address
                    && payment.amount_sompi == plan.commit_amount_sompi
                    && !payment.send_all
            }
            "prepareKaspacomReveal" => {
                let operation = parse::<crate::RevealRequest>(raw(a)?)?.operation;
                matches!(
                    operation.kind.as_str(),
                    "krc20-list" | "krc721-list" | "kns-list"
                ) && operation.sender == operation.recipient
            }
            "prepareKaspacomPskt" => review["profile"] == "kaspacom-market-v1",
            _ => false,
        };
        if method.starts_with("prepareKaspacom") && !in_app {
            return Err("Only locally validated KaspaCom operations support in-app review".into());
        }
        s.reviews.insert(
            hash,
            Review {
                operation: operation.into(),
                wallet: v.active.clone(),
                generation: s.generation,
                expires: now() + 10 * 60000,
                in_app,
                review: review.clone(),
            },
        );
        return encoded(review);
    }
    if matches!(
        method,
        "signTransaction"
            | "signReveal"
            | "signPskt"
            | "signKcc20Transfer"
            | "signEvmTransaction"
            | "signPolicyTransaction"
            | "signWyrmGenesis"
            | "signWyrmTransition"
            | "signDotkMarket"
            | "signCovenantVault"
    ) {
        let binding = native_binding(a)?;
        consume(s, v, a, method, &binding)?;
        let req: Value = parse(raw(a)?)?;
        let address = req["sender"]
            .as_str()
            .or(req["walletAddress"].as_str())
            .or(req["operation"]["sender"].as_str())
            .ok_or("Missing signing address")?;
        let aggregate =
            method == "signTransaction" && req["signers"].as_array().is_some_and(|r| !r.is_empty());
        let signing_wallet = wallet(v)?;
        if aggregate {
            let send: crate::SendRequest = parse(raw(a)?)?;
            let main = crate::address_with_prefix(address, false).map_err(error)?;
            let active = signing_wallet
                .addresses
                .iter()
                .find(|row| row["address"] == main)
                .ok_or("Unknown active HD account")?;
            for signer in &send.signers {
                let address = crate::address_with_prefix(&signer.address, false).map_err(error)?;
                let row = signing_wallet
                    .addresses
                    .iter()
                    .find(|row| {
                        row["address"] == address && row["derivationPath"] == signer.derivation_path
                    })
                    .ok_or(
                        "An account signing path is not registered with this encrypted wallet",
                    )?;
                if row["coinType"] != active["coinType"] || row["account"] != active["account"] {
                    return Err("Account signing paths span different HD accounts".into());
                }
            }
        }
        let secret = signing_secret(signing_wallet, address, aggregate)?;
        return core_sign(method, a, &secret);
    }
    match method {
        "initializeVault"=>Ok(Value::Null),
        "isHardwareBacked"=>Ok(json!(false)), // DPAPI is not Android StrongBox.
        "describeCovenantVault"=>encoded(crate::covenant_vault::descriptor(&parse(text(a,"terms")?)?).map_err(error)?),
        "validateVaultRecord"=>encoded(crate::vault_recovery::validate_record(text(a,"record")?).map_err(error)?),
        "loadCovenantVaults"=>encoded(&wallet(v)?.covenant_vaults),
        "saveCovenantVaults"=>{
            let raw=text(a,"catalog")?;if raw.len()>4*1024*1024{return Err("Vault journal too large".into())}
            let catalog:Vec<Value>=parse(raw)?;validate_vault_catalog(&catalog)?;
            let w=v.wallets.iter_mut().find(|w|w.id==v.active).ok_or("No active wallet")?;
            if w.covenant_vaults.iter().any(|old|!catalog.iter().any(|new|new["record"]["covenantId"]==old["record"]["covenantId"])){
                return Err("Saved vaults and signed recovery transactions cannot be silently removed.".into());
            }
            w.covenant_vaults=catalog;save(h,v)?;Ok(Value::Null)
        },
        "exportVaultRecovery"=>{
            let record=crate::vault_recovery::validate_record(text(a,"record")?).map_err(error)?;
            let password=h.ask(1,"Export vault recovery","Choose a recovery password with at least 12 characters. Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87 protect this file. No seed or private key is included.")?;
            let repeat=h.ask(1,"Confirm recovery password","Enter the same recovery password again.")?;
            if *password!=*repeat{return Err("Recovery passwords do not match".into())}
            let encrypted=crate::vault_recovery::seal(password.as_bytes(),&record.to_string()).map_err(error)?;
            let name=format!("Kaspire-Vault-{}.json",text(&record,"covenantId")?);
            let path=h.ask(5,"Save vault recovery file",&name)?;
            std::fs::write(path.as_str(),encrypted).map_err(|_|"Cannot save recovery file")?;
            Ok(json!(path.as_str()))
        },
        "importVaultRecovery"=>{
            let path=h.ask(4,"Choose a vault recovery file","JSON recovery files")?;
            if std::fs::metadata(path.as_str()).map_err(|_|"Cannot open recovery file")?.len()>512*1024{return Err("Recovery file too large".into())}
            let raw=std::fs::read_to_string(path.as_str()).map_err(|_|"Cannot read recovery file")?;
            let password=h.ask(1,"Import vault recovery","Enter the recovery file password.")?;
            let record=crate::vault_recovery::open(password.as_bytes(),&raw).map_err(error)?;
            Ok(Value::String(record))
        },
        "hasPin"=>Ok(json!(!v.pin_hash.is_empty())),
        "verifyPin"=>{verify_pin(h,v,s)?;s.until=now()+unlock_minutes(a)*60000;Ok(json!(true))},
        "refreshWindowsUnlock"=>Ok(json!(refresh_unlock(s,a))),
        "configurePin"=>{if !v.pin_hash.is_empty(){verify_pin(h,v,s)?;}configure_pin(h,v)?;invalidate(s);Ok(json!(true))},
        "removePin"=>Err("The Windows signing wallet requires a Kaspire PIN. You can change it, but cannot disable it.".into()),
        "setInternalNexusUnlocked"=>{let enabled=a["enabled"]==true;if !enabled{let authenticated_until=s.until;invalidate(s);s.until=authenticated_until;}else{if s.until<now(){return Err("Unlock Kaspire before accessing Nexus Offers.".into())}s.nexus=true;}Ok(Value::Null)},
        "lockWindowsSession"=>{invalidate(s);Ok(Value::Null)},
        "hasNativeWallet"=>{let address=a["address"].as_str();Ok(json!(v.wallets.iter().any(|w|address.is_none_or(|a|w.addresses.iter().any(|r|r["address"]==a)))))},
        "getNativeAddress"=>Ok(v.wallets.iter().find(|w|w.id==v.active).map(|w|json!(w.address)).unwrap_or(Value::Null)),
        "listWallets"=>encoded(v.wallets.iter().map(|w|json!({"id":w.id,"name":w.name,"address":w.address,"kind":w.kind,"active":w.id==v.active,"addresses":w.addresses})).collect::<Vec<_>>()),
        "selectWallet"=>{let id=text(a,"walletId")?;if !v.wallets.iter().any(|w|w.id==id){return Err("Unknown wallet".into())}v.active=id.into();switch_wallet_session(s);save(h,v)?;Ok(Value::Null)},
        "renameWallet"=>{let id=text(a,"walletId")?;let name=text(a,"name")?;if name.is_empty()||name.len()>120{return Err("Use a wallet name of 1–120 characters".into())}let w=v.wallets.iter_mut().find(|w|w.id==id).ok_or("Unknown wallet")?;w.name=name.into();save(h,v)?;Ok(Value::Null)},
        "deriveAddresses"=>{let secret=root_secret(wallet(v)?)?;let n=|k:&str,default:u32|a[k].as_u64().unwrap_or(default as u64) as u32;encoded(crate::derive_address_range(&secret,n("coinType",crate::MODERN_COIN_TYPE),n("account",0),n("change",0),n("start",0),n("count",20)).map_err(error)?)},
        "registerHdAddresses"=>{let rows:Vec<Value>=parse(text(a,"addresses")?)?;let secret=root_secret(wallet(v)?)?;let rows=verify_addresses(&secret,&rows)?;let w=v.wallets.iter_mut().find(|w|w.id==v.active).ok_or("No wallet")?;for row in rows{if let Some(old)=w.addresses.iter_mut().find(|old|old["address"]==row["address"]){*old=row;}else{w.addresses.push(row);}}save(h,v)?;Ok(Value::Null)},
        "createWallet"|"importWallet"|"importPrivateKey"=>{
            if s.until<now(){verify_pin(h,v,s)?;}
            let(address,secret)=if method=="importPrivateKey" {let key=h.ask(1,"Import private key","Enter the 64 hexadecimal characters of your Kaspa private key.")?;let m=crate::import_private_key(&key).map_err(error)?;(m.address.clone(),Zeroizing::new(format!("private:{}",m.private_key)))}else{
                let pass=h.ask(1,"BIP39 passphrase (optional)","Enter the optional BIP39 passphrase, or leave this field empty. A different passphrase creates a different wallet.")?;
                let material=if method=="createWallet" {let count=a["wordCount"].as_u64().unwrap_or(24) as usize;crate::generate_wallet_with_word_count(&pass,count).map_err(error)?}else{let phrase=h.ask(2,"Import recovery phrase","Enter your 12 or 24 recovery words, separated by spaces.")?;crate::import_wallet_with_passphrase(&phrase,&pass).map_err(error)?};
                if method=="createWallet" {h.info("Write down your recovery phrase",&material.mnemonic)?;let confirm=h.ask(2,"Verify recovery phrase","Enter the recovery phrase you just saved. Never share it with anyone.")?;if confirm.split_whitespace().collect::<Vec<_>>()!=material.mnemonic.split_whitespace().collect::<Vec<_>>(){return Err("Recovery phrase verification failed. No wallet was saved.".into())}}
                (material.address.clone(),mnemonic_secret(&material.mnemonic,&pass))
            };store_wallet(h,v,&secret,&address,"Wallet")?;switch_wallet_session(s);Ok(json!(address))
        },
        "authorizeOperation"|"authorizeKaspacomOperation"=>{
            let operation=text(a,"operation")?;let binding=text(a,"binding")?;
            let silent=operation=="signInternalNexusChallenge"&&s.nexus&&s.until>=now()&&valid_nexus(binding);
            if !silent {
                if operation.starts_with("sign")&&!matches!(operation,"signPersonalMessage"|"signInternalNexusChallenge") {
                    let r=s.reviews.get(binding).ok_or("No native review for this signing request")?;
                    if r.operation!=operation||r.wallet!=v.active||r.generation!=s.generation||r.expires<now(){return Err("Secure review expired. Review the transaction again.".into())}
                    let in_app=method=="authorizeKaspacomOperation"&&r.in_app;
                    if !in_app {h.ask(3,"Review transaction — Kaspire Rust core",&serde_json::to_string_pretty(&r.review).map_err(error)?)?;}
                }else{let display=serde_json::to_string_pretty(&json!({"operation":operation,"binding":binding})).map_err(error)?;h.ask(3,"Authorize Kaspire",&display)?;}
                if s.until<now()||a["sessionMinutes"]==0||operation.starts_with("export")||operation=="deleteWallet" {verify_pin(h,v,s)?;}
            }
            let token=id()?;s.tokens.retain(|_,t|t.expires>now());s.tokens.insert(token.clone(),Token{operation:operation.into(),binding:binding.into(),wallet:v.active.clone(),generation:s.generation,expires:now()+60000});
            if !silent{s.until=now()+a["sessionMinutes"].as_u64().unwrap_or(5).min(60)*60000;}Ok(json!(token))
        },
        "publicKey"=>{let address=text(a,"address")?;let secret=signing_secret(wallet(v)?,address,false)?;encoded(json!({"publicKey":crate::public_key(&secret).map_err(error)?}))},
        "deriveEvmAddress"=>{let w=wallet(v)?;let secret=signing_secret(w,&w.address,false)?;encoded(json!({"address":crate::derive_evm_address(&secret).map_err(error)?}))},
        "signPersonalMessage"|"signInternalNexusChallenge"=>{let binding=native_binding(a)?;consume(s,v,a,method,&binding)?;if method=="signInternalNexusChallenge"&&(!s.nexus||!valid_nexus(&binding)){return Err("Invalid internal Nexus authentication".into())}let address=text(a,"address")?;let secret=signing_secret(wallet(v)?,address,false)?;encoded(json!({"signature":crate::sign_personal_message(&secret,address,text(a,"message")?).map_err(error)?}))},
        "exportPrivateKey"|"exportPrivateKeys"=>{let address=text(a,"address")?;consume(s,v,a,"exportPrivateKey",address)?;let secret=signing_secret(wallet(v)?,address,false)?;let key=Zeroizing::new(crate::export_private_key(&secret).map_err(error)?);if method=="exportPrivateKeys"{let evm=Zeroizing::new(crate::export_evm_private_key(&secret).map_err(error)?);let display=Zeroizing::new(format!("Kaspa private key:\n{}\n\nEVM private key (Kasplex / Igra):\n{}",key.as_str(),evm.as_str()));h.info("Private keys — never share these",&display)?;}else{h.info("Private key — never share this",&key)?;}Ok(Value::Null)},
        "exportRecoveryPhrase"=>{let binding=wallet(v)?.address.clone();consume(s,v,a,method,&binding)?;let secret=root_secret(wallet(v)?)?;if secret.starts_with("private:"){return Err("Private-key wallets do not have a recovery phrase".into())}let phrase=secret.splitn(3,':').last().unwrap_or("");h.info("Recovery phrase — never share this",phrase)?;Ok(Value::Null)},
        "exportEncryptedBackup"=>{let binding=wallet(v)?.address.clone();consume(s,v,a,method,&binding)?;backup(h,v)},
        "restoreEncryptedBackup"=>{if s.until<now(){verify_pin(h,v,s)?;}let result=restore(h,v)?;switch_wallet_session(s);Ok(result)},
        "deleteWallet"=>{let id=text(a,"walletId")?;consume(s,v,a,method,id)?;v.wallets.retain(|w|w.id!=id);if v.active==id{v.active=v.wallets.first().map(|w|w.id.clone()).unwrap_or_default();}invalidate(s);save(h,v)?;Ok(Value::Null)},
        "prepareInscription"=>encoded(crate::prepare_inscription(&parse::<crate::InscriptionRequest>(raw(a)?)?).map_err(error)?),
        "prepareKronTransfer"=>encoded(crate::prepare_kron_transfer(&parse::<crate::KronTransferRequest>(raw(a)?)?).map_err(error)?),
        "deriveDotkDeed"=>encoded(crate::dotk::derive(&parse::<crate::dotk::Request>(raw(a)?)?).map_err(error)?),
        "describeDotkMarket"=>Ok(json!(crate::describe_dotk_market_json(raw(a)?).map_err(error)?)),
        "prepareNftMarket"=>Ok(json!(crate::prepare_nft_market_json(raw(a)?).map_err(error)?)),
        "prepareKaspacomMarket"=>Ok(json!(crate::prepare_kaspacom_market_json(raw(a)?).map_err(error)?)),
        "normalizeKaspacomTransport"=>Ok(json!(crate::normalize_kaspacom_transport_json(text(a,"pskt")?,text(a,"buyer")?).map_err(error)?)),
        "verifyUpdateManifest"=>Ok(json!(false)), // Never accept an Android APK on Windows.
        "verifyDesktopUpdateManifest"=>{updates::verify(&h.directory,text(a,"payload")?,text(a,"signature")?)?;Ok(json!(true))},
        "prepareDesktopUpdate"=>updates::prepare(&h.directory,text(a,"payload")?,text(a,"signature")?),
        "installDesktopUpdate"=>{invalidate(s);updates::install(text(a,"token")?)},
        "cancelDesktopUpdate"=>updates::cancel(text(a,"token")?),
        "saveVaultRecovery"=>{
            let name=text(a,"fileName")?;let content=text(a,"json")?;
            if !name.starts_with("kascoven-")||!name.ends_with(".json")||name.len()>220||!name.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'||b==b'_'||b==b'.')||content.len()>512*1024{return Err("Unsupported Vault recovery filename or size".into())}
            let record:Value=parse(content)?;
            if record["protocol"]!="kascoven-vault-recovery-v1"||record["network"]!="kaspa-mainnet"||!matches!(record["type"].as_str(),Some("time_lock"|"dead_man_switch")){return Err("Not a KasCoven recovery file".into())}
            fn secret_fields(v:&Value)->bool{match v{Value::Object(o)=>o.iter().any(|(k,v)|{let key=k.to_lowercase().replace(['_','-'],"");["mnemonic","seed","privatekey","password","secret"].iter().any(|s|key.contains(s))||secret_fields(v)}),Value::Array(a)=>a.iter().any(secret_fields),_=>false}}
            if secret_fields(&record){return Err("Recovery metadata must not contain secrets".into())}
            let path=h.ask(5,"Save Vault recovery file",name)?;std::fs::write(path.as_str(),content).map_err(|_|"Cannot write recovery file")?;Ok(json!(path.as_str()))
        },
        "getTangemDiagnostic"=>encoded(json!({"available":false,"reason":"Tangem NFC is not available in the Windows desktop build."})),
        "clearTangemDiagnostic"|"cancelTangemSession"=>Ok(Value::Null),
        _=>Err(format!("{method} is not available in the Windows build yet. No transaction was signed."))
    }
}

/// Called only by the native Windows runner, not by a WebView or Dart FFI.
/// The response never contains an unencrypted mnemonic/private key/password.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaspire_desktop_call(
    input: *const c_char,
    length: usize,
    directory: *const c_char,
    prompt: Prompt,
    free: PromptFree,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> R<Value> {
        if input.is_null() || directory.is_null() || length > 4 * 1024 * 1024 {
            return Err("Invalid Windows native call".into());
        }
        let raw = unsafe { std::slice::from_raw_parts(input.cast::<u8>(), length) };
        let request: Value = serde_json::from_slice(raw).map_err(|_| "Invalid Windows request")?;
        let directory = unsafe { CStr::from_ptr(directory) }
            .to_str()
            .map_err(|_| "Invalid Windows data path")?;
        let cancellation = CANCELLATION.load(Ordering::SeqCst);
        let host = Host {
            prompt,
            free,
            directory: PathBuf::from(directory),
            cancellation,
        };
        let mut session = SESSION
            .get_or_init(|| Mutex::new(Session::default()))
            .lock()
            .map_err(|_| "Windows signing session unavailable")?;
        if session.cancellation != cancellation {
            let authenticated_until = session.until;
            invalidate(&mut session);
            session.until = if FORGET_AUTH.swap(false, Ordering::SeqCst) {
                0
            } else {
                authenticated_until
            };
            session.cancellation = cancellation;
        }
        let mut vault = load(&host)?;
        let output = dispatch(
            &host,
            text(&request, "method")?,
            &request["arguments"],
            &mut vault,
            &mut session,
        )?;
        if CANCELLATION.load(Ordering::SeqCst) != cancellation {
            return Err(
                "Wallet locked during the operation. No signed transaction was released.".into(),
            );
        }
        Ok(output)
    });
    let envelope = match result {
        Ok(Ok(v)) => json!({"result":v}),
        Ok(Err(e)) => json!({"error":e}),
        Err(_) => {
            json!({"error":"The Windows security core rejected an invalid request. No new transaction was signed."})
        }
    };
    CString::new(envelope.to_string()).unwrap().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaspire_desktop_free(p: *mut c_char) {
    if !p.is_null() {
        let mut b = unsafe { CString::from_raw(p) }.into_bytes_with_nul();
        b.zeroize();
    }
}
/// Lock cancellation must not wait for the mutex held by a native modal dialog.
#[unsafe(no_mangle)]
pub extern "C" fn kaspire_desktop_cancel() {
    CANCELLATION.fetch_add(1, Ordering::SeqCst);
}
#[unsafe(no_mangle)]
pub extern "C" fn kaspire_desktop_lock() {
    FORGET_AUTH.store(true, Ordering::SeqCst);
    kaspire_desktop_cancel();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_unlock_refresh_never_revives_expired_or_locked_sessions() {
        let mut s = Session {
            nexus: true,
            ..Default::default()
        };
        assert!(!refresh_unlock(&mut s, &json!({"sessionMinutes":15})));
        switch_wallet_session(&mut s);
        assert_eq!(s.until, 0);
        assert!(!s.nexus);
        s.until = now() + 30000;
        s.nexus = true;
        let original = s.until;
        switch_wallet_session(&mut s);
        assert_eq!(s.until, original);
        assert!(!s.nexus);
        s.nexus = true;
        assert!(refresh_unlock(&mut s, &json!({"sessionMinutes":15})));
        assert!(s.until > original);
        invalidate(&mut s);
        assert!(!refresh_unlock(&mut s, &json!({"sessionMinutes":15})));
    }
    #[test]
    fn windows_pin_tokens_are_operation_wallet_generation_and_binding_bound() {
        let mut s = Session::default();
        let v = Vault {
            active: "w1".into(),
            ..Default::default()
        };
        s.tokens.insert(
            "a".into(),
            Token {
                operation: "signPskt".into(),
                binding: "review".into(),
                wallet: "w1".into(),
                generation: 0,
                expires: now() + 10000,
            },
        );
        assert!(consume(
            &mut s,
            &v,
            &json!({"authorizationToken":"a"}),
            "signPskt",
            "changed"
        )
        .is_err());
        assert!(!s.tokens.contains_key("a"));
    }
    #[test]
    fn wallet_switch_or_lock_invalidates_all_prepared_authorizations() {
        let mut s = Session {
            until: now() + 1000,
            nexus: true,
            ..Default::default()
        };
        invalidate(&mut s);
        assert_eq!(s.until, 0);
        assert!(!s.nexus);
        assert_eq!(s.generation, 1);
    }
    #[test]
    fn desktop_and_android_share_the_review_hash_and_core() {
        let request = json!({"sender":"bad-address","utxosJson":"[]","recipient":"bad-address","amountSompi":1,"feeRate":1.0});
        assert!(core_prepare(
            "prepareTransaction",
            &json!({"request":request.to_string()})
        )
        .is_err());
    }
    #[test]
    fn untrusted_hd_metadata_cannot_register_a_different_wallet() {
        let secret="mnemonic:abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let rows =
            crate::derive_address_range(secret, crate::MODERN_COIN_TYPE, 0, 0, 0, 1).unwrap();
        let mut rows: Vec<Value> = rows
            .iter()
            .map(|r| serde_json::to_value(r).unwrap())
            .collect();
        assert!(verify_addresses(secret, &rows).is_ok());
        rows[0]["derivationPath"] = json!("m/44'/111111'/0'/0/1");
        assert!(verify_addresses(secret, &rows).is_err());
    }

    #[test]
    fn internal_nexus_auth_is_origin_purpose_and_expiry_bound() {
        let issued = chrono::Utc::now();
        let expires = issued + chrono::Duration::minutes(5);
        let address = "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";
        let message=format!("{address}\0Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: {address}\nNonce: {}\nIssued at: {}\nExpires at: {}\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.","a".repeat(43),issued.to_rfc3339(),expires.to_rfc3339());
        assert!(valid_nexus(&message));
        assert!(!valid_nexus(&message.replace(
            "Domain: kaspire.kaslab.space",
            "Domain: attacker.example"
        )));
        assert!(!valid_nexus(
            &message.replace("internal-private-offers-v1", "transaction-signing")
        ));
        assert!(!valid_nexus(&message.replace(
            &expires.to_rfc3339(),
            &(issued - chrono::Duration::minutes(1)).to_rfc3339()
        )));
    }

    #[cfg(target_os = "windows")]
    mod windows {
        use super::*;
        use std::{cell::RefCell, collections::VecDeque};
        static NATIVE_TESTS: Mutex<()> = Mutex::new(());
        thread_local! {static ANSWERS:RefCell<VecDeque<String>>=RefCell::new(VecDeque::new());}
        unsafe extern "C" fn prompt(
            _mode: u32,
            _title: *const c_char,
            _text: *const c_char,
        ) -> *mut c_char {
            let answer = ANSWERS.with(|q| q.borrow_mut().pop_front());
            answer
                .map(|a| CString::new(a).unwrap().into_raw())
                .unwrap_or(std::ptr::null_mut())
        }
        unsafe extern "C" fn release(p: *mut c_char) {
            unsafe { kaspire_desktop_free(p) }
        }
        fn answers(rows: &[&str]) {
            ANSWERS.with(|q| *q.borrow_mut() = rows.iter().map(|s| s.to_string()).collect());
        }
        struct Fixture(Host);
        impl Fixture {
            fn new() -> Self {
                let path =
                    std::env::temp_dir().join(format!("kaspire-desktop-native-{}", id().unwrap()));
                std::fs::create_dir(&path).unwrap();
                Self(Host {
                    prompt,
                    free: release,
                    directory: path,
                    cancellation: CANCELLATION.load(Ordering::SeqCst),
                })
            }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0.directory);
            }
        }
        #[test]
        fn dpapi_roundtrip_uses_the_current_windows_user() {
            let _guard = NATIVE_TESTS.lock().unwrap();
            let clear = b"disposable native test data";
            let cipher = protect(clear, true).unwrap();
            assert_ne!(cipher.as_slice(), clear);
            assert_eq!(protect(&cipher, false).unwrap().as_slice(), clear);
        }
        #[test]
        fn encrypted_wallet_persists_without_returning_or_storing_a_clear_seed() {
            let _guard = NATIVE_TESTS.lock().unwrap();
            let f = Fixture::new();
            let h = &f.0;
            let material = crate::generate_wallet().unwrap();
            let secret = mnemonic_secret(&material.mnemonic, "");
            let mut vault = Vault::default();
            store_wallet(h, &mut vault, &secret, &material.address, "Disposable").unwrap();
            let persisted = std::fs::read(h.directory.join("wallets.dpapi")).unwrap();
            assert!(!persisted
                .windows(material.mnemonic.len())
                .any(|s| s == material.mnemonic.as_bytes()));
            let loaded = load(h).unwrap();
            assert_eq!(
                root_secret(wallet(&loaded).unwrap()).unwrap().as_str(),
                secret.as_str()
            );
            let info = dispatch(
                h,
                "listWallets",
                &json!({}),
                &mut vault,
                &mut Session::default(),
            )
            .unwrap()
            .to_string();
            assert!(!info.contains(&material.mnemonic));
            assert!(!info.contains("protectedSecret"));
        }
        #[test]
        fn wrong_pin_fails_and_native_cancellation_does_not_unlock() {
            let _guard = NATIVE_TESTS.lock().unwrap();
            let f = Fixture::new();
            let h = &f.0;
            let mut vault = Vault::default();
            answers(&["123456", "123456"]);
            configure_pin(h, &mut vault).unwrap();
            let mut session = Session::default();
            answers(&["654321"]);
            assert!(verify_pin(h, &mut vault, &mut session).is_err());
            assert_eq!(session.until, 0);
            answers(&[]);
            assert!(verify_pin(h, &mut vault, &mut session).is_err());
            assert_eq!(session.until, 0);
            answers(&["123456"]);
            assert!(verify_pin(h, &mut vault, &mut session).unwrap());
            assert!(session.until > now());
        }
        #[test]
        fn android_v3_backup_roundtrips_wallet_and_verified_hd_addresses() {
            let _guard = NATIVE_TESTS.lock().unwrap();
            let f = Fixture::new();
            let h = &f.0;
            let material = crate::generate_wallet().unwrap();
            let secret = mnemonic_secret(&material.mnemonic, "optional passphrase");
            let material =
                crate::import_wallet_with_passphrase(&material.mnemonic, "optional passphrase")
                    .unwrap();
            let mut vault = Vault::default();
            store_wallet(h, &mut vault, &secret, &material.address, "Disposable").unwrap();
            let path = h.directory.join("disposable-backup.json");
            let terms = crate::covenant_vault::Terms {
                kind: "timeLock".into(),
                owner: material.address.clone(),
                beneficiary: String::new(),
                limit_daa: 5000,
                instance: "03".repeat(32),
                name: "Backup fixture".into(),
            };
            let mut record = crate::covenant_vault::descriptor(&terms).unwrap();
            record["protocol"] = json!(crate::covenant_vault::PROTOCOL);
            record["terms"] = serde_json::to_value(terms).unwrap();
            record["covenantId"] = json!("ab".repeat(32));
            record["transactionId"] = json!("cd".repeat(32));
            record["index"] = json!(0);
            record["amountSompi"] = json!(100_000_000u64);
            record["status"] = json!("locked");
            let catalog = vec![json!({"record":record})];
            validate_vault_catalog(&catalog).unwrap();
            vault.wallets[0].covenant_vaults = catalog.clone();
            save(h, &vault).unwrap();
            let path = path.to_string_lossy().into_owned();
            answers(&[
                "disposable backup password",
                "disposable backup password",
                &path,
            ]);
            backup(h, &vault).unwrap();
            let envelope: Value = parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(envelope["format"], "kaspire-backup-v3");
            assert_eq!(envelope["memoryKiB"], 65536);
            assert_eq!(envelope["iterations"], 4);
            let mut restored = Vault::default();
            answers(&[&path, "disposable backup password"]);
            assert_eq!(restore(h, &mut restored).unwrap(), json!(material.address));
            assert_eq!(wallet(&restored).unwrap().covenant_vaults, catalog);
            assert_eq!(
                root_secret(wallet(&restored).unwrap()).unwrap().as_str(),
                secret.as_str()
            );
            assert_eq!(
                wallet(&restored).unwrap().addresses,
                wallet(&vault).unwrap().addresses
            );
        }
    }
}
