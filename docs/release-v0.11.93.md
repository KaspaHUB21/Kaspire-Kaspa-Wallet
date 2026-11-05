# Kaspire Android 0.11.93 — KForge Mainnet swaps

Public Android release, build 238. Complete changes since public Android
0.11.87 / build 232; versions 0.11.88–0.11.92 were direct-download builds, not
public-channel releases. Android 11 or later; ARM64 and ARMv7.

## KForge on Mainnet and Testnet 10

- Mainnet Swap venue order is KaspaRocket, Kasseal, Braid, KForge, KRON.
  KForge supports the pinned v6 bonding-curve and pool buy/sell paths on both
  Mainnet and Testnet 10, with network-specific APIs, contract parameters,
  fee destinations and encrypted recovery journals.
- Buy always takes the KAS trade amount, not a requested token quantity. For
  curves, exact integer arithmetic selects the largest affordable lot count.
  The entered budget, tokens, amount used and lot-rounding remainder are
  checked by the native core and bound to the approved review. Protocol fees,
  network fees and any new token-cell reserve are disclosed separately in the
  all-in wallet payment. Sell continues to take token quantities.
- The official KForge mark, token previews, searchable catalogue, DEX swaps /
  My activity tabs, 50-entry activity pages and Load more follow the existing
  Kaspire flow. The comparison notice mentioning KasForge has been removed.
- Confirmed swaps open a persistent trade-details screen with token quantity,
  KAS paid/received, fees, reserves, date, copyable transaction and covenant IDs,
  and Return to KForge DEX. Pending or uncertain submissions are not labelled
  completed; reopening does not silently resubmit a transaction.
- KForge token holdings appear progressively in KCC20 assets, with official
  metadata/images and registry-checked whole-token units. Slow catalogues or
  missing metadata do not erase known holdings or turn unavailable prices and
  balances into zero. Kasvio did not yet provide complete KForge metadata or
  token units during the readiness checks, so the official KForge discovery
  path supplements it rather than guessing decimals.
- Before signing, the shared Rust core reconstructs pinned contracts and all
  transaction outputs, checks live inputs independently, verifies the approved
  review, fees and mass, and executes every signed input locally. Signed bytes
  are saved and read-back-verified in the encrypted journal before submission.
  Recovery retains identical bytes until confirmation or positively proven
  obsolescence; an unavailable lookup does not release a saved payment.

Generic KForge asset transfers, arbitrary recipient policies, multi-cell merges,
launch/claim flows and automatic graduation transactions are not newly enabled.
The supported integration is the verified API prepare/submit swap flow.

## KasForge Testnet 10 maintenance

- Update public SDK order templates to 0.5.1 for contracts 3.8: buy v5 for
  contracts 3.7/3.8, buy v4 for 3.4–3.6, and sell v4 for 3.4 and later.
  Previously supported saved orders keep byte-identical recovery. Unknown or
  inconsistent declared versions fail closed.
- Support stepSubmit multi-step builds: persist and independently confirm the
  already signed prefix before reviewing/signing a dependent step. Resume does
  not re-sign an existing prefix or report a partial plan as a completed order.
- Apply version-bound sell token-cell reserves and locally calculated,
  review-bound network-fee limits. Cancellation returns excess reserve.
- Refresh the fixed independent Testnet 10 node endpoint and bound read
  connection lifetimes, fallback and cleanup. Missing or stalled node results
  remain explicitly unavailable. KasForge remains Testnet-10-only.

Original confidential partner kits and SilverScript sources are not included
in the repository or APK. Published integration data consists of the verifier,
pinned program data, public-chain fixtures and tests.

## Updates and platform scope

The official-website download and the in-app GitHub release update deliver the
same release-signed APK. Existing Android package identity, signing certificate
and lineage, publishable client configuration, WalletConnect identity and signed
update trust are retained. Install over the existing app; do not uninstall or
clear wallet data. Android still requires installation approval.

Browser extension 0.5.27, Chrome Web Store status, Windows, iOS PWA and their
update channels are unchanged. Separate KaspaCom recovery experiments are not
included. Website changes update download metadata and the KForge feature
description; release notes remain on GitHub only.

## Verification

163 native core tests and 1,121 Flutter tests passed; 18 optional live/snapshot
tests were explicitly skipped. Five bounded TN10 node-reader lifecycle and
failure tests also passed. Focused analysis found no errors or warnings
(49 informational style diagnostics).

The release re-runs the full offline Rust/Flutter regression suite and checks
the actual ARM64/ARMv7 APK, native-library provenance, official logo, corrected
KAS-buy UI, absence of the removed comparison notice, package/version, signing
identity, 16-KB alignment and compiled public-client configuration. Readiness
checks used unsigned public Mainnet prepares and independent node data;
complete signing/VM tests use synthetic local keys. No funded live swap or
physical-device end-to-end settlement is claimed.

Android signing-certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

Official APK: https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.93.apk

GitHub APK: https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.93/Kaspire-Android-mainnet-v0.11.93.apk

Checksum: https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.93.apk.sha256

APK SHA-256:
`6441aea6fec3b8218af97e92069c8f915c40d7a652bd2440dc54ca9e6d52aabe`.

All changes since the last public Android release:
https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.87...v0.11.93
