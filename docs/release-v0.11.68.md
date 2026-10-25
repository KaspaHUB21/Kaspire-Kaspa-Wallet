# Kaspire Android 0.11.68 — Update options and Kasseal Browser

Android build **211**, package `space.kaspire.wallet`, ARM64 and ARMv7,
Android 11+. Complete Android changes since **0.11.67**.
The browser extension remains **0.5.27**, with no new ZIP or Chrome Store change.
Windows is unchanged. [Extension 0.5.27 release notes](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/extension-v0.5.27).

## Two update paths, one trusted release

- The home-screen update action and Settings → Kaspire updates open a themed
  in-app choice dialog. Choose **Download from official website** or
  **Download & install from GitHub**. No permanent default is forced.
- The website option retains the familiar external-browser APK download from
  Kaspire's official website, followed by manual Android installation.
- The GitHub option downloads the matching official release APK inside Kaspire,
  shows download/verification progress, and opens Android's installer without an
  external browser. It still downloads a complete APK; it is not remote code
  loading, an APK-free patch or a silent installation.
- Both options use the existing cryptographically signed Android update manifest.
  GitHub is a download source, not a replacement trust authority. Derive the exact
  versioned APK asset URL; do not follow GitHub's mixed-platform Latest release.
- Native Android code re-verifies the manifest, complete SHA-256, package name,
  version/build and signing continuity before opening the installer. Reject
  downgrades/previously superseded manifests, arbitrary URLs and untrusted
  redirects. Bound HTTPS redirects, download size and total operation time.
- Store APKs only in the private updater cache. A non-exported, restricted
  FileProvider grants the installer read access to the selected update, not
  wallet files or backup folders. Wallet signing and storage remain unchanged.
- Android may ask to allow **Install unknown apps** for Kaspire. After granting
  permission, return and tap **Continue installation**. Normal Android install
  confirmation still applies. Opening the installer is not displayed as success.
- Keep the update session/verified APK when auto-lock or navigation interrupts
  the permission handoff. Explicit Cancel/Close can abandon the download. Failure
  leaves retry and the official website option available, with readable messages.
- Preserve existing wallet data, signing certificate/rotation lineage and signed
  update trust. This release adds the specific `REQUEST_INSTALL_PACKAGES`
  permission for the user-selected internal installation flow.

**First installation:** install 0.11.68 using the existing APK-download flow.
The new chooser can install the **next newer signed release** when it is
published; it does not offer to reinstall the currently installed build.

## Kasseal in Kaspire Browser

- Add **Kasseal** at `https://app.kasseal.com/`, with its official
  `favicon-512.png` packaged locally for reliable display.
- Browser selection order is now **Kasvio → Kasseal → GothDAG → dot.k →
  Kaspa News → Kaspa Dev Tools → KasCoven Vaults**.
- Approve only the exact HTTPS Kasseal origin, not arbitrary subdomains,
  lookalike hosts, alternate ports or insecure HTTP.
- Retain the existing in-app WalletConnect flow and all origin restrictions.
  Kaspa News remains read-only. Kasseal DEX transaction/signing code is unchanged.

## Verification

- **686 Flutter tests passed**, including all themes/narrow-screen layouts,
  both update choices, permission return, installer handoff, readable errors,
  cancellation, auto-lock disposal and the new browser order/origin policy.
- **Three native Kotlin update-policy tests passed**, including exact release
  binding, allowed/hostile redirects, downgrade rejection and signer continuity.
- Changed Dart files passed static analysis. The release APK was built with
  both rebuilt Rust native ABIs and the required Android/Reown client settings.
- Verified APK version/build, alignment, v3 signature, release certificate,
  restricted FileProvider/permission and packaged Kasseal icon. Read-only checks
  confirmed the actual GitHub asset redirect/size and Kasseal's mobile connector.
- No real financial transaction was signed or broadcast for these checks. A
  physical-device end-to-end installation via the new path remains to be checked
  with the subsequent newer release; server/widget tests are not that validation.

## Download

- [Official Android APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.68.apk)
- [GitHub APK asset](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.68/Kaspire-Android-mainnet-v0.11.68.apk)
- SHA-256: `865c934e8684f3c6ff332fdd5f6d55061a7a26105bf5c84d2662c90d660aa1ed`
- Release certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
- [Source comparison: 0.11.67 → 0.11.68](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.67...v0.11.68)

Install over the existing app rather than uninstalling it. Keep an up-to-date
encrypted backup, including P2SH journals and pending transactions where used.
