# Kaspire Android 0.11.80 Braid and Nexus fixes

Build **225**, Android 11+, ARM64 and ARMv7. Complete Android and supporting
Nexus service changes since public **0.11.79/build 224**. The extension remains
**0.5.27**; Windows and iOS update channels are unchanged.

## Braid two step swap fees

- Fix **Staged KAS differs from the independent sale valuation** for supported
  two-step token-to-token routes, including GUZA → KAS → THEN. Braid quotes
  its 1% partner fee against the gross sale value, while Kaspire previously
  compared that basis with proceeds after the DEX fee.
- Derive both gross sale value and net proceeds independently from the same
  pinned pool state and integer arithmetic. The app and Rust signing core now
  check the fee against gross value; the intermediate payment guarantee still
  uses net proceeds. Fee limits, partner-address checks and recovery protections
  remain enforced. The fee description now identifies its gross basis.
- Preserve atomic routes and saved receipts. A two-step route remains
  non-atomic: if its second purchase cannot complete, the recoverable asset
  after the first sale is KAS, not the original tokens.

## Nexus Offers

- Repair Kaspire login verification for **My offers**, notifications and private
  offers. Initialize the Kaspa verifier at service startup, validate public-key
  formats and match the Schnorr key to the selected wallet. Remove the obsolete
  ECDSA conversion and misleading **Kasware returned an invalid public key**
  wording. Nexus does not connect to KasWare.
- Fix **Make private offer** appearing unresponsive when login fails. The app
  now catches authentication errors, displays connection progress at the button
  and reports failures visibly near the user's current position. Failed or
  cancelled authentication does not submit an offer; another attempt is possible.
- Guard pending offer actions against repeated taps, keep the selected NFT
  attached to its offer and reconnect before confirmed private offer actions
  when the local session has expired.
- Preserve the requested My offers view on login failure. An unavailable
  dashboard no longer displays a misleading **No results found** message.
- Make first-login wallet registration safe when background polling and opening
  Nexus happen concurrently. Public-key and signature checks, challenge expiry,
  replay rejection and private dashboard authorization remain enforced.
- Private offers remain non-binding: authentication and offer submission do not
  create a blockchain transaction, lock funds or spend funds.

## Verification and installation

- **152 Rust tests** and **881 Flutter tests** passed in the complete offline
  regression run; eleven opt-in or fixture-dependent Flutter checks were skipped.
  **48 focused Braid Flutter checks** and **23 Nexus Flutter checks** also passed.
  Nexus dialogs were checked in all ten
  themes at a 320-pixel phone width, including slow login, errors and retry.
- Five read-only production quote/pool checks passed: GUZA → THEN, THEN → GUZA,
  KRON → PEPE and the existing atomic THEN ↔ KRON routes. No funded swap was
  executed as part of these checks.
- The deployed Nexus service accepts Kaspire's real Rust/WASM login signatures
  from an unfunded synthetic wallet, including concurrent first-login requests.
  Invalid signatures, challenge replay and unauthenticated private access were
  rejected. My offers and notifications loaded for that wallet; no real offers
  or payments were created. Local cryptographic and protocol tests also passed.
- Both update choices install the same signed APK: the official website
  download or the matching GitHub release downloaded inside Kaspire. Install
  over the existing app; **do not uninstall**. Android installation approval
  remains required. The signed update manifest and website download metadata
  are updated; release notes remain GitHub-only.
- APK version, client configuration, 16 KB alignment and v3 signature were
  checked. The release certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.80.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.80/Kaspire-Android-mainnet-v0.11.80.apk)
- [APK SHA-256](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.80.apk.sha256)
- APK SHA-256: `96592217f5857e3f5d65204731930aa5beaa03c633b3a86da9f6accc1f9f832a`.
- [All changes since 0.11.79](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.79...v0.11.80)
