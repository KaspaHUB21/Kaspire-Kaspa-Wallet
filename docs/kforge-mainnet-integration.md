# KForge Mainnet integration

## Public Android 0.11.93 / 238

The tested Mainnet/TN10 integration, subsequent KAS-buy correction and removal
of the KasForge comparison notice are promoted to the public Android channel.
See [the cumulative release notes](release-v0.11.93.md) for scope, update paths
and verification limits. The sections below record the earlier test evidence.

## Android test 0.11.91 / 236

Separate direct-download test APK. The public Android manifest, mainnet-latest
APK, website content, iOS and browser extension are unchanged. KForge and
KasForge remain distinct integrations. TN10 remains available with its own
API, pinned programs, address prefix and encrypted receipt namespace.

## Mainnet readiness checks (2026-11-05)

- `https://api.kforge.xyz/v6/registry` reports Mainnet v6 and the same source
  fingerprints/compiler commit as the privately supplied, independently
  compiled contracts. Mainnet base is 6,249,997,720 sompi and slope is
  15,644,550 sompi, both ten times TN10. The protocol-fee recipient also differs.
- Compiled separate Mainnet program pins using those constants and fee script.
  Matched exact input script commitments in five publicly prepared, unsigned
  curve/pool buy/sell examples, including a P2SH creator-fee recipient. The
  creator-fee script is a destination, not an additional wallet signer.
- Checked every exact input against Kaspire's independent wRPC-backed Mainnet
  UTXO reader. The ordinary local REST UTXO response omits covenant IDs; it is
  deliberately not used to authorize these trades.
- Tested original captured plans through the app's quote adapter and native
  `prepare_pskt`; tested complete witnesses using synthetic local-only keys and
  outputs through the Rust VM. No public wallet was signed, no funded trade
  was executed and no transaction was submitted during these checks.

## UX and assets

Mainnet venue order: KaspaRocket, Kasseal, Braid, KForge, KRON. The KForge
catalogue, official mark, token previews, DEX swaps / My activity tabs,
individual trade reviews, persistent success details, copy actions and Return
to KForge DEX use the same widgets as TN10. Network labels and image hosts are
selected explicitly. All ten themes retain the narrow-layout checks.

KForge holdings are discovered progressively in the Mainnet KCC20 wallet list.
Positive quantities do not wait for Kasvio or a full catalogue; metadata
failure does not erase a known positive holding. A failed request is not zero.
Confirmed receipts refresh the wallet only after encrypted journal readback.
Native signing rechecks inputs, quantities, owner policies, change, fees,
review hash, mass and contract execution. Recovery preserves identical signed
bytes until confirmation or positively proven obsolescence.

## Kasvio status and intentional limits

The checked Mainnet catalogue contained 21 tokens. Twenty detail requests
returned recognized `KCC20Parameterized@v1-i6-o6` contracts with unknown token
units and null metadata; one request was rate-limited. The explicit KASUSD
metadata route also returned null. Kasvio's status was `catching_up`.
Therefore Kasvio cannot yet provide complete KForge names/images/decimals.
Kaspire uses the official KForge catalogue/holdings as supplemental discovery,
with registry-checked whole-token units (zero decimals), exact covenant IDs
and the official image host. It does not guess eight decimals or claim that
Kasvio has verified those units. Existing Kasvio discovery remains unchanged.

Generic KForge token transfers, arbitrary token policies, multi-cell merges,
launching, claiming and automatic curve-to-pool graduation transactions are
not enabled by this patch. These are the existing scope limits, not newly
claimed signing support. API prepare/submit swaps and exact-byte recovery are
the supported paths.

## Build verification

- 162 native core tests passed; all five captured Mainnet paths also execute
  with synthetic signatures in the local VM.
- Full Flutter regression: 1,079 passed, 18 optional live/snapshot tests skipped.
  Targeted KForge run: 82 passed, one optional TN10 snapshot test skipped.
- Analyzer: no errors or warnings; 46 informational style diagnostics.
- Actual APK: `space.kaspire.wallet`, 0.11.91 / 236, Android 11+, ARM64/ARMv7,
  existing v3 signing identity and lineage, 16-KB alignment, public-client
  configuration verified. Both packaged native libraries match the newly
  verified offline builds after normal stripping. No private kits or sources
  are packaged.
- Direct download:
  `https://kaspire.kaslab.space/downloads/Kaspire-Android-v0.11.91-KForge-mainnet-test.apk`
- SHA-256: `cbc4e2311dc40c0602521f661a3097587ea1d5f57fce43693e78be1f7bbd6df4`
