# Kaspire Android 0.11.101 — Kasvio V4, verified KCC20 fallback and L2 QR scanning

Public Android release, build 246. Complete changes since public Android
0.11.99/build 244, including the previously test-only 0.11.100 L2 QR fix.
Android 11 or later; ARM64 and ARMv7.

## KCC20 discovery and sending during Kasvio outages

- Move Standard-KCC20 discovery, token details, balances, transaction evidence,
  diagnostics and verified-image URLs to Kasvio's public `/api/kcc20/v4` API.
  The complete cursor-paginated catalogue was verified read-only at 580 tokens.
  V4 is a multi-family indexer: its null global reference revision is accepted
  only in a network-bound V4 envelope, not as a new signing template or a waiver
  of any local contract checks. Native signing support is not broadened.
- Preserve Kasseal's restricted owner mode when V4 identifies its venue.
  Unassigned V4 identities can be resolved through Kascov, so known retired
  profiles remain excluded rather than returning as wallet errors. Metadata
  image paths are built from the V4 base instead of copying old V1 image links
  still present in some server records. The separate KRON-native API is a
  different protocol: KRON remains its own balance/signing source, with its
  existing optional `/api/kron/v2` presentation feed unchanged.
- Kasvio remains the primary Standard-KCC20 reader. Kascov now provides a
  per-read fallback for address holdings, token identity, balances and current
  cell proofs used to prepare transfers. This includes failures occurring after
  the initial balance has already loaded, not only initial wallet discovery.
- A short shared outage backoff avoids repeatedly hammering an unavailable
  primary API while fallback reads are succeeding. No signature or broadcast
  is automatically retried by this mechanism.
- Kascov's exact cell programs must match the locally bundled, pinned 3-input
  or 10-input contract template. Amount, owner scheme, owner, receiving policy,
  extension commitment and the program's Blake2b/P2SH commitment are checked.
  Every selected origin and live UTXO is still verified through Kaspire's own
  node, and the unchanged native Rust signer reconstructs and checks the plan.
- Modern Standard-KCC20 fallback holdings use the correct modern signing
  path, fixing the misleading legacy-template rejection affecting the Kaspire
  test token. UNNACHOD and other supported Kasseal owner transfers can obtain
  their cells without depending exclusively on Kasvio.
- Preserves eligible Borrowed Receive, token-class separation, existing
  contract-specific input/output limits and reviewed whole-payment compound
  plans. Kasseal retains its separate owner-only mode and reserve restrictions;
  this does not add Kasseal Borrowed Receive or support for arbitrary programs.
- Remove KCC20.info from Android discovery and diagnostics entirely. Known
  unsupported pre-final token contracts no longer reappear through Kascov.
  Diagnostics now identify Kasvio and Kascov separately; own-node read failures
  are labelled as own-node failures.
- Truncated/unproven cells, malformed rows, wrong networks, changed owners,
  mismatched commitments and already-spent outputs fail closed. Stale or
  incomplete snapshots remain explicitly partial, with positive results kept.
  Fallback current-cell evidence is not misrepresented as complete historical
  activity. Existing encrypted recovery journals and saved signed bytes remain
  unchanged. If neither indexer or the required node proofs are available,
  Kaspire cannot safely authorize a transfer and will not assume zero funds.

## Igra and Kasplex L2 QR fix

- The Android L2 recipient scanner accepts a plain `0x` plus 40 hexadecimal
  characters instead of incorrectly demanding a `kaspa:` Layer 1 address.
- Scan prompts name the selected L2 network. A scan result is discarded if
  the active network changed while the scanner was open.
- Layer 1 keeps its existing Kaspa payment parsing. Payment/function URIs are
  not silently converted to plain EVM recipients. Duplicate scan handling and
  scan-subscription cleanup are retained.

## Updating and validation

Both update choices remain available: the official website APK and the matching
GitHub-release APK inside Kaspire, through the existing signed Android update
manifest and unchanged signing identity. Install over the existing app; do not
uninstall or clear wallet data. Android still requires installation approval.

The native ARM64/ARMv7 signing libraries are byte-identical to public 0.11.99.
Validation includes the Rust suite, Flutter regressions, hostile fallback-cell
mutations, stale/partial-state checks and the actual built APK's identity,
configuration and packaged content. Public goatmilk.kas Kaspire/UNNACHOD cells
were captured read-only, checked with own-node proofs and passed to the real
Rust unsigned-plan builder with invented local fee funding. No real-wallet
signature, payment or trade submission was performed.

Extension, iOS PWA and Windows releases and update channels are unchanged.
Website version/checksum/download metadata is updated; release notes remain
on GitHub, not embedded beneath the website download buttons.

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.101.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.101/Kaspire-Android-mainnet-v0.11.101.apk)
- [Checksum](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.101.apk.sha256)
- [Changes since 0.11.99](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.99...v0.11.101)

Validation: 167 Rust tests and 1,176 full-suite Flutter tests passed (18 optional
fixture/live-environment skips). Both captured unsigned Kaspire/UNNACHOD plans
also passed real native reconstruction. Analyzer reports no errors or warnings;
29 informational brace-style hints remain. APK verification confirms both ABIs,
the approved public client configuration, unchanged signing identity and native
cores, the new V4/fallback/QR code, absence of old KCC20 V1/V2/V3 routes and
absence of the retired KCC20.info URL. A second read-only capture verifies all
580 V4 catalogue entries with opaque cursor paging, goatmilk.kas holdings, V4
image paths, Kasseal's owner-only mode and native-ready cells against own-node
data.

APK SHA-256:
`1752a3ef84500bb929865071f78c74822cafb776d72e6bc28706e130499885af`.
