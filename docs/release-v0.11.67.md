# Kaspire Android 0.11.67 — Borrowed Receive and verified KCC20 activity

Build **210**, package `space.kaspire.wallet`, **ARM64 and ARMv7**, Android 11+.
Complete Android changes since public **0.11.66**. The extension's cumulative
release is published separately as **0.5.27**; Windows is unchanged.

## Borrowed Receive for standard KCC20 and KaspaRocket

- Reuse a live recipient token cell instead of creating another on every receipt,
  when its amount-threshold policy explicitly permits the incoming increase.
- Preserve recipient ownership, the entire guard, extended token identity,
  existing tokens and KAS deposit. Authorize sender inputs only; do not forge a
  recipient signature or bypass disabled/separately authorized receiving policies.
- Verify indexed state against accepted own-node outputs and current live UTXOs.
  Native deterministic rebuilding, review binding and local VM execution remain
  mandatory before returning signed transaction bytes.
- Spend existing owner-authorized standard cells carrying receiving policies.
  New standard receiving/change cells allow future positive borrowed receipts.
  Signature/hash-chain policies are not permissionless and are not automatically
  consumed without their required authorization.
- Respect the pinned 3/3 or 10/10 program's limits. Reserve a recipient input
  slot; reviewed consolidation/payment plans borrow only in the final payment,
  not in preceding sender self-consolidation transactions.
- The review states whether a cell is reused, none is eligible, or optional reuse
  discovery was unavailable. Use a new receiving cell in the latter cases instead
  of consuming unverified recipient data.
- **Kasseal and legacy KRON production paths remain unchanged.** Borrowed Receive
  is not newly enabled through those separate swap/transfer integrations.

## Correct KCC20 activity units and merging

- Resolve verified token units before falling back to verified genesis metadata,
  including parameterized actor-family receipts. Missing/unverified decimals do
  not silently become an eight-decimal display amount.
- Prefer verified covenant receipts over legacy fallback amounts. Merge by
  transaction and covenant identity, including legacy ticker aliases for the
  same token, so later fallback results cannot overwrite verified units.
- The reported BTE transaction
  `7aebbce2de0f5f107050aaba13c25417bbb823413507376e259bb6977ff603c7`
  has `250000` recipient raw units with **three verified decimals**: **250 BTE**,
  not the old fallback display. This corrects history; it does not change the
  already broadcast amount or make a replacement transfer.
- Retain the progressive 50-entry Activity/Load more flow, persistent KRC20 logo
  cache and WalletConnect fixes from 0.11.66 and earlier.

## Verification

- **677 Flutter tests** and **134 native Rust library tests** passed. Focused
  changed-file Dart analysis passed.
- Both native Android ABIs rebuilt. Package/version/build, APK alignment, v3
  signature, signing continuity and public client/Reown configuration verified.
- Rocket read/trade gateway and Kasseal unsigned-planner readiness checked
  read-only. Native signing/VM fixtures use synthetic keys and outpoints, not
  funded wallets. No real financial transaction was broadcast for validation.
- Publish the exact already verified 0.11.67 APK without changing its bytes.
  Existing release certificate and rotation lineage remain unchanged. Physical
  Android device testing is not claimed by the server-side checks.

## Update and downloads

The signed Android manifest advertises **0.11.67 / build 210**. Install over the
existing app; do not uninstall. Keep a current encrypted backup, including saved
P2SH state and pending transactions where applicable.

- [Android APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.67.apk)
- SHA-256: `0cbcd76ffaeb69c78dfb8bfdb3f5eb0997779ca2dbb5d79c36cb913a0283d55a`
- Release certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
- [Source comparison: 0.11.66 → 0.11.67](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.66...v0.11.67)
