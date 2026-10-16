Kaspire for Windows 0.1.5 (x64)
==============================

Installation
------------
Run Kaspire-Windows-0.1.5-x64-Setup.exe. Kaspire installs for your Windows user,
without requiring administrator access, and creates a desktop shortcut.
Windows 10 1809 or newer / Windows 11 x64 is required.
The installer does not yet have a Windows publisher certificate; Windows may
display an unknown-publisher warning. The in-app updater verifies the separate
Kaspire release signature and installer checksum before running it.

The portable ZIP is also available: extract the entire folder and run kaspire.exe.
Keep all DLLs and the data folder beside it. No compilation is needed.

Wallet protection
-----------------
Wallet secrets are encrypted with Windows DPAPI for your Windows user account.
The case-sensitive Kaspire password authorizes access in the app; it is not a
second encryption key. Letters, numbers, spaces and symbols are supported
(6-128 characters). Existing numeric PINs remain valid. An eye button can show
or hide the native password input without sending its contents to Flutter.
There is no separate TPM-backed key store. Malware running as your Windows user
is outside this protection boundary. Signing and review use the native Rust core.

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
