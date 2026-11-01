# Kaspire Android 0.11.84 — Faster KCC20 discovery and stable token identity

Build **229**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.83/build 228**. This release is Android-only: the browser
extension remains **0.5.27**, and Windows/iOS update channels are unchanged.

## Address-scoped KCC20 discovery

- Use Kasvio's public `/api/kcc20/v1/addresses/{address}/tokens?limit=100`
  endpoint instead of walking the global token catalogue and requesting a
  separate owner balance for every supported token.
- Resolve the pinned token program and verified metadata only for positive
  holdings. Publish each identified holding progressively, before optional
  Activity-origin reads finish. Token images continue to use Kasvio's public,
  hash-addressed `/api/kcc20/v1/images/{sha256}` API.
- Preserve exact raw quantities and verified token units. Check the response
  network, reference revision, address and owner; reject mismatched token
  identities, unsupported templates and conflicting decimals.
- Follow opaque address-page cursors with bounded pagination, duplicate
  detection and snapshot consistency checks. A later page failure retains
  already discovered holdings and reports incomplete discovery.
- Preserve the legacy catalogue path only when the address endpoint explicitly
  reports unsupported/not found (404/405). Network errors and rate limits do
  not initiate a global fallback scan or imply a zero balance.
- Keep Activity-origin discovery for held tokens and the existing independent
  wallet-history loaders. No global token-history scan is added to the new
  address-based path.

## NACHO / STD identity conflict

- KRON's indexer also returns imported standard KCC20 tokens, with internal
  routing tickers such as `STD-41D44970BA63`. Do not expose these imported
  `kcc20v1` rows as KRON-native wallet assets or let them replace the standard
  token's name, image, units or signing classification.
- Real KRON-native holdings remain available independently. Existing
  KaspaRocket and Kasseal venue discovery is unchanged. The correction does
  not depend on Kasvio winning a network-response race.

## Honest loading and partial-state UI

- Show KCC20 discovery warnings in the asset overview, including progressive
  results. Preserve positive holdings when optional origin reads fail.
- Distinguish still-loading, incomplete and successfully empty asset lookups.
  Do not label a pending or incomplete lookup as a confirmed empty wallet.
- Use existing theme colors and wrapping text; no new theme or screen layout
  is introduced.

## Verification and update delivery

- **152 native Rust tests** and **972 Flutter tests** passed. Sixteen opt-in or
  fixture-dependent Flutter checks were skipped in the offline suite; the new
  live address check was run separately against the production API.
- Tests cover address/owner/network identity, verified 0/3/6/8 decimal units,
  progressive positives, failed optional reads, later page failures, repeated
  cursors, snapshot changes, duplicate holdings, incomplete/empty discovery,
  caller timeouts/reopening and both KRON/standard arrival orders. Existing
  sending, Borrowed Receive, consolidation and history regressions also pass.
- The final APK's package/version, both ABI payloads, publishable client
  configuration, pinned WalletConnect identity, CRCs, 16 KB alignment and
  release signature were checked. Both native signing libraries are
  byte-identical to 0.11.83. No physical Android device was attached for this
  build; the live check exercises the actual Dart service against real API
  responses, not an end-to-end phone transaction.
- Read-only live verification of the production API, using a public NACHO
  holder, published the first positive holding in **354 ms** and completed
  discovery including Activity origins in **667 ms**. These are measurements
  from the build server, not a guarantee of mobile-network latency. No wallet
  secret was imported and no transaction was signed or broadcast.
- Signing, script reconstruction, own-node live-output validation, fees and
  recovery behavior are unchanged. Indexed holdings remain observed data;
  they are not treated as ready-to-sign cells.
- Both update choices deliver the same APK: official website download or the
  matching GitHub release downloaded inside Kaspire. The signed update
  manifest is promoted only after the GitHub APK is publicly downloadable.
  Android still requires installation approval. Install over the existing app;
  **do not uninstall or clear app data**.
- Website changes are download version/checksum metadata only. Release notes
  remain on GitHub, not embedded in the website's download section.
- Release certificate SHA-256:
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.84.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.84/Kaspire-Android-mainnet-v0.11.84.apk)
- [APK SHA-256](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.84.apk.sha256)
- APK SHA-256: `99ffbf8471b2983ca9c716fc64203b371f0054ba0fd5a3ec088c585315020be9`.
- [All changes since 0.11.83](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.83...v0.11.84)
