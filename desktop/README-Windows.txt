Kaspire for Windows 0.1.6 (x64)
==============================

Installation
------------
Run Kaspire-Windows-0.1.6-x64-Setup.exe. Kaspire installs for your Windows user,
without requiring administrator access, and creates a desktop shortcut.
Windows 10 1809 or newer / Windows 11 x64 is required.
The installer does not yet have a Windows publisher certificate; Windows may
display an unknown-publisher warning. The in-app updater verifies the separate
Kaspire release signature and installer checksum before running it.

The portable ZIP is also available: extract the entire folder and run kaspire.exe.
Keep all DLLs and the data folder beside it. No compilation is needed.

Wallet protection
-----------------
Wallet secrets use AES-256-GCM with a random 256-bit master key. Argon2id v1.3
(64 MiB, 4 iterations, parallelism 1) derives a wrapping key from your
case-sensitive Kaspire password. The encrypted store is additionally protected
by Windows DPAPI for your Windows user account. DPAPI alone cannot decrypt the
wallet secrets in this format. No password-derived decryption key is stored.
Letters, numbers, spaces and symbols are supported (6-128 characters); choose
a long, unique password. Existing numeric PINs remain valid. Older DPAPI-only
stores are atomically upgraded after the first successful password check.
After upgrading storage, do not downgrade to an older Windows wallet. Keep an
encrypted portable backup; it remains the recovery path across installations.
An eye button can show or hide native password input without sending it to
Flutter. The session key is cleared on lock and password changes rotate it.
There is no separate TPM-backed key store. Malware running while your wallet
is unlocked can still compromise it. Signing and review use the native Rust core.

Optional BIP39 seed passphrases use Unicode NFKD normalization in Windows.
The Windows unlock password is NOT normalized: case and spaces remain exact.
The signing core clears transient signing keys and Argon2 workspaces on drop.

Windows build hardening
-----------------------
The build script enables ASLR, high-entropy VA, DEP and Control Flow Guard for
the Kaspire EXE and Rust signing DLL and checks the resulting PE headers and
CFG instrumentation. External prebuilt libraries are not claimed to be rebuilt.
No trusted Authenticode certificate is configured yet. Without one, Windows
may report an unknown publisher. Ed25519 update signatures remain separate.
Once a trusted certificate is installed in the Windows CurrentUser\My store,
run Build-Windows.ps1 -SigningCertificateThumbprint <thumbprint>
-RequireAuthenticode. The build signs and verifies the EXE and Rust DLL.
After creating the installer, sign and verify that EXE with Sign-Windows.ps1
-Path <installer.exe> -CertificateThumbprint <thumbprint> BEFORE calculating
release hashes or signing the update manifest. Do not distribute private keys
or certificate passwords in the source package. Self-signing is not a substitute
for a trusted publisher certificate.

Backup and recovery
-------------------
Settings > Backups offers Argon2id backup export and import. New backups use the
same v3 format as Android: Argon2id v1.3 (64 MiB, 4 iterations, parallelism 1),
AES-256-GCM, a random 32-byte salt and 12-byte IV. Android v2/v3 imports are
supported. Both the wallet and its saved covenant-vault recovery journal are
included. Keep a verified encrypted backup and its password separately.

Covenant Vaults opens the same Time-Locked and Dead Man's Switch flows as Android,
with the same Rust/SilverScript contracts and encrypted recovery-file format.

Updates
-------
Kaspire checks a separate signed Windows update manifest and offers an in-app
update dialog. The installer is downloaded from the official GitHub release.
The native core verifies the pinned Ed25519 manifest signature, platform, release
URL, signed file size and SHA-256 before launching the installer. Kaspire closes
during installation and opens again afterward. Android updates are separate.
Windows 0.1.2 and 0.1.3 require one manual installer upgrade. The corrected
Windows updater is included in 0.1.4 and newer.

Data location
-------------
%LOCALAPPDATA%\Kaspire holds encrypted wallets and saved recovery state.
Installation, updates and uninstalling program files do not delete that directory.
Never delete it for troubleshooting without a verified backup.

Building from source
--------------------
Use Flutter 3.47.5, Rust 1.97.1, Visual Studio 2022 C++ Build Tools and Windows SDK.
Run desktop\Build-Windows.ps1 in PowerShell. The script validates native code,
Flutter analysis and desktop widgets, then builds the complete Windows bundle.
