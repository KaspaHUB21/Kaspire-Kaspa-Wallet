# Kaspire Android 0.11.79 Braid two step swaps

Build **224**, Android 11+, ARM64 and ARMv7. Complete Android and supporting
gateway changes since public **0.11.78/build 223**. Extension **0.5.27**, Windows
and iOS remain unchanged.

## Braid token to token routes

- Support Braid's two-step routes between the pinned KaspaRocket tokens, such
  as **GUZA → KAS → THEN**, and between the pinned KRON tokens. Previously,
  a staged quote could fail with **Braid quote differs from the selected swap**.
  Atomic routes remain supported; custom or unverified token contracts are not
  enabled by this change.
- A two-step route uses one signed wallet deposit but **is not an atomic
  token-to-token exchange**. The first sale cannot be reversed. If the second
  purchase fails, the recoverable asset is intermediate **KAS**, not the
  original tokens. The quote and deposit review now explain this distinction.
- Bind the intermediate KAS guarantee to independently read, pinned pool
  state, with bounded quote/read drift and the reviewed slippage floor.
  The native core checks the approved route, destination minimum, nonce,
  deadline, contract fingerprints and transaction before signing.
- Check the disclosed **1% partner fee** in KAS against the independently
  valued first sale for staged routes. Returned KAS reserves are not counted
  as trade value. Atomic token-to-token routes retain their separate
  token-fee and reserve checks; executable-minimum fee waivers remain supported.

## Confirmation and recovery

- Derive the second router script locally from the saved original terms.
  Preserve recipient, refund key, destination token, minimum, fees, deadline
  and intent; clear only the input-side fields and intermediate minimum.
- Follow the accepted first transaction spending the exact original coin
  and token-note outpoints. Verify its intermediate output script and value
  before accepting a final payment that spends that intermediate coin.
- Support owner-signed recovery after the deadline both before the first sale
  and from the intermediate KAS coin after it. Recovery uses the saved receipt
  and independent node data rather than requiring Braid's server to cooperate.
  Network fees still apply; the local recovery fee cap remains **0.05 KAS**.
- Preserve encrypted receipts across reopening, missing status replies and
  unavailable or incomplete node history. Unknown state never marks a swap
  complete or authorizes a replacement deposit. Intermediate-history searches
  use bounded pagination and report incomplete results explicitly.

## Local node pool reads

- Include the gateway fix deployed after 0.11.78: make an omitted protobuf
  script version explicitly **0** in successful local-node UTXO responses.
  This prevents valid pool outputs from being misclassified as spent and
  causing repeated **Pool changed; its new state is not indexed yet** errors.
  Explicit versions and other chain data are preserved; unavailable data is
  not invented or replaced with zero balances.

## Verification and installation

- **151 Rust tests** and **876 Flutter tests** passed in the full offline
  regression run; eight opt-in or fixture-dependent Flutter checks were skipped.
  **48 focused Flutter checks** were subsequently run against the final route
  changes, including production quote/pool verification and the actual
  Dart-to-Rust recovery request boundary. All passed.
- Native tests sign and locally execute staged Rocket deposits, original-token
  recovery and intermediate KAS recovery with the pinned Mainnet programs.
  Additional tests cover KRON intermediate recovery, changed fees and terms,
  unrelated transactions, incorrect intermediate outputs and unavailable data.
  No funded Mainnet swap or physical-device end-to-end swap was executed.
- The built APK contains the new signing core for both ARM ABIs. Version,
  client configuration, 16 KB alignment and v3 signature were checked.
  The release certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
- Both update choices use the same signed APK and checksum: the official
  website download or the matching GitHub release downloaded inside Kaspire.
  The signed Android update manifest is updated. Install over the existing
  app; **do not uninstall**. Android still requires installation approval.
  Website download metadata is updated; release notes remain GitHub-only.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.79.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.79/Kaspire-Android-mainnet-v0.11.79.apk)
- APK SHA-256: `7051860b4b122414755bd0ea1149a69dad7007ee2f32b4b7ae4e347bdbd2e7bf`.
- [All changes since 0.11.78](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.78...v0.11.79)
