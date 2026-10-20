//! Windows-only signed installer channel. Never trust a URL, checksum or path
//! supplied by Flutter without verifying the pinned release signature again.
use super::{error, id, now, protect, R};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Release {
    platform: String,
    version: String,
    build: u64,
    minimum_build: u64,
    critical: bool,
    published_at: String,
    installer_url: String,
    sha256: String,
    size_bytes: u64,
    release_notes_url: String,
}
#[derive(Default, Serialize, Deserialize)]
struct Highest {
    build: u64,
    published: i64,
}
struct Prepared {
    release: Release,
    path: PathBuf,
    expires: u64,
}
static PREPARED: OnceLock<Mutex<HashMap<String, Prepared>>> = OnceLock::new();
pub(super) fn installed() -> Value {
    serde_json::from_str(include_str!("../../../desktop/version.json")).expect("desktop version")
}
fn parse_with_key(payload: &str, signature: &str, key: &[u8; 32]) -> R<Release> {
    if payload.len() > 32768 || signature.len() > 128 {
        return Err("Windows update manifest is too large.".into());
    }
    let bytes = B64.decode(payload).map_err(|_| "Invalid update payload")?;
    let sig = Signature::from_slice(
        &B64.decode(signature)
            .map_err(|_| "Invalid update signature")?,
    )
    .map_err(error)?;
    VerifyingKey::from_bytes(key)
        .map_err(error)?
        .verify_strict(&bytes, &sig)
        .map_err(|_| "Windows update signature is invalid. Nothing will be installed.")?;
    let r: Release =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid Windows release fields")?;
    let version_parts: Vec<_> = r.version.split('.').collect();
    let expected_url=format!("https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/windows-v{0}/Kaspire-Windows-{0}-x64-Setup.exe",r.version);
    let expected_notes = format!(
        "https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/windows-v{}",
        r.version
    );
    if r.platform != "windows-x64"
        || version_parts.len() != 3
        || version_parts.iter().any(|p| {
            p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit()) || p.parse::<u16>().is_err()
        })
        || r.build == 0
        || r.minimum_build == 0
        || r.minimum_build > r.build
        || r.installer_url != expected_url
        || r.release_notes_url != expected_notes
        || r.sha256.len() != 64
        || !r
            .sha256
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        || r.size_bytes < 1024
        || r.size_bytes > 512 * 1024 * 1024
        || chrono::DateTime::parse_from_rfc3339(&r.published_at).is_err()
    {
        return Err("Windows update manifest contains invalid release terms.".into());
    }
    Ok(r)
}
pub(super) fn verify(directory: &Path, payload: &str, signature: &str) -> R<Release> {
    let key: [u8; 32] = hex::decode(include_str!("../../../desktop/update-signing-key.hex").trim())
        .map_err(error)?
        .try_into()
        .map_err(|_| "Invalid pinned update key")?;
    let r = parse_with_key(payload, signature, &key)?;
    let path = directory.join("desktop-updates.dpapi");
    let highest: Highest = if path.exists() {
        serde_json::from_slice(&protect(&std::fs::read(&path).map_err(error)?, false)?)
            .map_err(error)?
    } else {
        Highest::default()
    };
    let published = chrono::DateTime::parse_from_rfc3339(&r.published_at)
        .map_err(error)?
        .timestamp_millis();
    if r.build < highest.build || (r.build == highest.build && published < highest.published) {
        return Err("An older Windows update was rejected. Nothing will be installed.".into());
    }
    if r.build > highest.build || published > highest.published {
        std::fs::create_dir_all(directory).map_err(error)?;
        let cipher = protect(
            &serde_json::to_vec(&Highest {
                build: r.build,
                published,
            })
            .map_err(error)?,
            true,
        )?;
        let temporary = directory.join(format!("update-state-{}.tmp", id()?));
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(error)?;
        file.write_all(&cipher)
            .and_then(|_| file.sync_all())
            .map_err(error)?;
        drop(file);
        std::fs::rename(&temporary, &path).map_err(error)?;
    }
    Ok(r)
}
pub(super) fn prepare(directory: &Path, payload: &str, signature: &str) -> R<Value> {
    let release = verify(directory, payload, signature)?;
    if release.build <= installed()["build"].as_u64().unwrap() {
        return Err("This Windows version is already installed or newer.".into());
    }
    let token = id()?;
    let folder = directory.join("updates").join(&token);
    std::fs::create_dir_all(&folder).map_err(error)?;
    let path = folder.join("Kaspire-Setup.exe");
    let result = json!({"token":token,"path":path,"installerUrl":release.installer_url,"sizeBytes":release.size_bytes,"critical":release.critical});
    let mut pending = PREPARED
        .get_or_init(Default::default)
        .lock()
        .map_err(error)?;
    pending.retain(|_, p| p.expires > now());
    if pending.len() >= 2 {
        return Err("An update is already being downloaded.".into());
    }
    pending.insert(
        token,
        Prepared {
            release,
            path,
            expires: now() + 30 * 60000,
        },
    );
    Ok(result)
}
pub(super) fn install(token: &str) -> R<Value> {
    let mut pending = PREPARED
        .get_or_init(Default::default)
        .lock()
        .map_err(error)?;
    let prepared = pending
        .remove(token)
        .ok_or("Update authorization expired. Check for updates again.")?;
    if prepared.expires < now() {
        return Err("Update download expired. Retry the download.".into());
    }
    let locked = locked_installer(&prepared.path)?;
    let mut file = &locked.file;
    if file.metadata().map_err(error)?.len() != prepared.release.size_bytes {
        return Err("Incomplete update download. Nothing was installed.".into());
    }
    let mut hash = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = file.read(&mut buf).map_err(error)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    if hex::encode(hash.finalize()) != prepared.release.sha256 {
        return Err("Update checksum mismatch. Nothing was installed.".into());
    }
    #[cfg(target_os = "windows")]
    {
        // Keep the no-write/no-delete file handle AND ancestor directory
        // handles alive through CreateProcess. Locking only the file would
        // still allow its pathname to be redirected by renaming a parent.
        std::process::Command::new(&locked.path)
            .args([
                "/SILENT",
                "/SUPPRESSMSGBOXES",
                "/NORESTART",
                "/CLOSEAPPLICATIONS",
            ])
            .spawn()
            .map_err(|_| "The verified installer could not start. Try again.")?;
        Ok(json!(true))
    }
    #[cfg(not(target_os = "windows"))]
    Err("Windows installers can only run on Windows.".into())
}
struct LockedInstaller {
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    path: PathBuf,
    file: std::fs::File,
    _directories: Vec<std::fs::File>,
}
fn locked_installer(path: &Path) -> R<LockedInstaller> {
    let path = std::fs::canonicalize(path).map_err(|_| "The update download is missing.")?;
    #[cfg(target_os = "windows")]
    let mut directories = Vec::new();
    #[cfg(not(target_os = "windows"))]
    let directories = Vec::new();
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        const FILE_SHARE_READ: u32 = 1;
        const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        let ancestors: Vec<_> = path
            .parent()
            .ok_or("Invalid installer path")?
            .ancestors()
            .collect();
        for parent in ancestors.into_iter().rev() {
            let handle = std::fs::OpenOptions::new().read(true)
                .share_mode(FILE_SHARE_READ)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .open(parent).map_err(|_| "Cannot secure the installer directory. Close other programs and download the update again.")?;
            let metadata = handle.metadata().map_err(error)?;
            if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
            {
                return Err("Installer directory changed. Nothing was installed.".into());
            }
            directories.push(handle);
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1).custom_flags(0x00200000); // read sharing only; do not follow a substituted reparse point
    }
    let file = options.open(&path).map_err(|_| {
        "Cannot secure the installer. Close other programs and download the update again."
    })?;
    let metadata = file.metadata().map_err(error)?;
    if !metadata.is_file() {
        return Err("Installer is not a regular file".into());
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err("Installer path changed. Nothing was installed.".into());
        }
    }
    Ok(LockedInstaller {
        path,
        file,
        _directories: directories,
    })
}
pub(super) fn cancel(token: &str) -> R<Value> {
    let mut pending = PREPARED
        .get_or_init(Default::default)
        .lock()
        .map_err(error)?;
    if let Some(p) = pending.remove(token) {
        let _ = std::fs::remove_file(&p.path);
        let _ = std::fs::remove_dir(p.path.parent().unwrap());
    }
    Ok(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    #[cfg(target_os = "windows")]
    #[test]
    fn installer_file_and_parent_paths_remain_locked_through_process_creation() {
        use std::process::{Command, Stdio};
        let root = std::env::temp_dir().join(format!("kaspire-installer-lock-{}", id().unwrap()));
        let folder = root.join("download");
        std::fs::create_dir_all(&folder).unwrap();
        let source = PathBuf::from(std::env::var_os("SystemRoot").unwrap())
            .join("System32")
            .join("cmd.exe");
        let path = folder.join("disposable-setup.exe");
        std::fs::copy(source, &path).unwrap();
        let locked = locked_installer(&path).unwrap();
        assert!(std::fs::OpenOptions::new().write(true).open(&path).is_err());
        assert!(std::fs::rename(&path, folder.join("replaced.exe")).is_err());
        assert!(std::fs::remove_file(&path).is_err());
        assert!(std::fs::rename(&folder, root.join("redirected")).is_err());
        assert!(std::fs::rename(&root, root.with_extension("redirected")).is_err());
        let status = Command::new(&locked.path)
            .args(["/D", "/C", "exit 0"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        drop(locked);
        std::fs::remove_dir_all(root).unwrap();
    }
    fn fixture() -> (Value, SigningKey) {
        (
            json!({"platform":"windows-x64","version":"0.1.4","build":5,"minimumBuild":1,"critical":false,"publishedAt":"2026-10-16T00:00:00Z","installerUrl":"https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/windows-v0.1.4/Kaspire-Windows-0.1.4-x64-Setup.exe","sha256":"ab".repeat(32),"sizeBytes":100000,"releaseNotesUrl":"https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/windows-v0.1.4"}),
            SigningKey::from_bytes(&[19; 32]),
        )
    }
    fn signed(v: &Value, k: &SigningKey) -> (String, String) {
        let bytes = serde_json::to_vec(v).unwrap();
        (B64.encode(&bytes), B64.encode(k.sign(&bytes).to_bytes()))
    }
    #[test]
    fn desktop_update_signature_and_repository_are_bound() {
        let (v, k) = fixture();
        let (p, s) = signed(&v, &k);
        assert!(parse_with_key(&p, &s, k.verifying_key().as_bytes()).is_ok());
        assert!(parse_with_key(&p, &s, &[1; 32]).is_err());
        let mut altered = v.clone();
        altered["sha256"] = json!("cd".repeat(32));
        assert!(parse_with_key(
            &B64.encode(serde_json::to_vec(&altered).unwrap()),
            &s,
            k.verifying_key().as_bytes()
        )
        .is_err());
    }
    #[test]
    fn signed_other_platform_url_and_unknown_fields_are_rejected() {
        let (v, k) = fixture();
        for (field, value) in [
            ("platform", "android"),
            ("installerUrl", "https://example.com/evil.exe"),
            (
                "releaseNotesUrl",
                "https://github.com/other/repo/releases/tag/v1",
            ),
            ("unexpected", "ignored"),
        ] {
            let mut v = v.clone();
            v[field] = json!(value);
            let (p, s) = signed(&v, &k);
            assert!(
                parse_with_key(&p, &s, k.verifying_key().as_bytes()).is_err(),
                "{field}"
            );
        }
    }
    #[test]
    fn installer_requires_a_live_native_token() {
        assert!(install("arbitrary-path.exe").is_err());
    }
}
