# Kaspire Android 0.11.64 — WalletConnect hotfix

Android build **207**, package `space.kaspire.wallet`, ARM64 and ARMv7,
Android 11+. The browser extension remains **0.5.23**.

- KRC20 dApp payment approvals fetch the requested token holdings directly.
  They no longer wait for a complete wallet scan, NFT discovery, DEX data,
  marketplace enrichment or unrelated transaction history.
- Reusable `kaspire://dapp` wake links are processed on every invocation,
  rather than being permanently suppressed after the first request.
- Pairing and wake links no longer wait behind the interactive approval queue
  they are intended to wake. Interactive approvals remain serialized.
- Temporary encrypted-relay initialization failures can be retried without
  restarting Kaspire. Concurrent initialization attempts are coalesced.
- Subscribe to WalletConnect events before SDK startup, preserving the
  verification context of early proposals. Restore non-expired pending
  proposals and requests after resume and while the app is in the foreground.
- Deduplicate recovered requests and proposals so restoring a pending request
  does not create another approval or signing operation.
- Keep connection permissions, scam checks, approved origins, user consent,
  Rust transaction reconstruction, device authorization and own-node checks.
  No signing safeguards have been removed.
- Preserve the existing APK signing certificate, signing lineage and signed
  Android update-manifest trust. Existing wallet data is retained on upgrade.

## Verification

- All **643 Flutter tests** pass, including seven WalletConnect recovery and
  real-widget approval regression tests. The widget test opens the GothDAG
  KRC20 review and then Kasvio and dot.k connection prompts without signing.
- Changed Dart files pass static analysis. Full-project analysis reports
  existing style-level notices in unrelated files, with no errors/warnings.
- The configured production Reown project connects to its relay and creates
  an unfunded pairing in a read-only connectivity check.
- No Android handset is attached to this build server; an end-to-end payment
  on a physical phone has not been performed. No funded transaction was
  signed or broadcast during verification.

APK SHA-256:
`354be96833b84dd72b21f0192fb9cd43e15bc1afbf0c14b87d306e820be66184`

Signing certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
