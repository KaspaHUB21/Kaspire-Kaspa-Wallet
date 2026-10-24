# Kaspire Android 0.11.67 & Extension 0.5.27

Combined release notes for **Android 0.11.66 → 0.11.67** and **browser extension
0.5.23 → 0.5.27**, including extension changes prepared in 0.5.24–0.5.26.
Android build **210**, package `space.kaspire.wallet`, **ARM64 and ARMv7**,
Android 11+. Windows is unchanged. The extension also has its own
[dedicated release](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/extension-v0.5.27).

## Android and extension: Borrowed Receive for standard KCC20 and KaspaRocket

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

## Android and extension: correct KCC20 activity units and merging

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

## Browser extension 0.5.27: optional Chrome Side Panel

- Add a split-window button to the header to open Kaspire beside the current
  webpage. This is opt-in: the ordinary popup remains the default. Close the
  panel with the button where supported or Chrome's own close control.
- Use the same packaged wallet UI and native Rust/WASM signing core in both
  surfaces. Adapt to panel width/height across Midnight, HUB21, Glacier and
  Neptune, including narrow 320px layouts and long asset/operation names.
- Add only the specific `sidePanel` permission; no new website host permissions.
  Chrome may request approval for the permission change.

## Browser extension 0.5.27: dApp approvals inside the panel

- Present connection, unlock and signing reviews directly inside the matching
  open panel in the requesting browser window, rather than opening separate
  windows. Without a matching panel, retain the ordinary approval popup.
- Verify Chrome's actual `SIDE_PANEL` document context. A normal tab opening
  the panel URL cannot present approvals. Do not route requests to a different
  browser window or guess between ambiguous requesters.
- Serialize reviews and bind each decision to the exact pending request ID.
  Closing the panel rejects unanswered approvals. Account/network, session,
  native review-hash and signing checks remain enforced.
- Unlocking does not authorize signing: explicit approval/rejection remains
  required. Wrong-password handling and ordinary popup fallback are retained.
- No heartbeat or auto-lock override. Closing a popup does not lock an open
  panel, but Immediately auto-lock still locks when the last wallet UI closes.
  Timed expiry still rejects stale approvals.

## Browser extension 0.5.27: progressive Activity, logos and layout

- Bring Android's independent, progressive Activity loading to the extension:
  KAS, KRC20, KRON, standard KCC20, legacy covenant, NFT/name and saved activity
  no longer wait for every asset-discovery source to finish.
- Initially show the latest **50 merged entries**. Load more adds 50, with
  bounded native/KRC20 pagination and deduplication. Failed sources retain loaded
  entries, mark incomplete coverage and offer Retry instead of implying no history.
- Read KRC20 history directly through Kasplex with a fallback. Keep internal
  amounts canonical and apply thousands separators only for display.
- Build standard KCC20 history from exact wallet-related receipts rather than
  global trading feeds. Cache complete details, coalesce requests and prioritize
  targeted history while retaining shared request pacing and HTTP 429 backoff.
- Use Kaspire's persistent KRC20 logo cache before market enrichment finishes.
  Saved logos survive upstream failures; first-time uncached images still need
  a working original source.
- Wrap/truncate long token names and operation labels within narrow cards;
  full information remains available in their details.

## Browser extension 0.5.27: immediate standard KCC20 balances

- Publish each validated positive holding immediately, independently of legacy
  indexers and later standard-token balance queries, matching Android.
- Reopened/concurrent views receive the active scan's already found holdings
  without starting a duplicate scan. A faulty display listener cannot interrupt
  discovery. Partial results are not cached as a complete or zero balance.
- Selecting an already found token can use its display metadata while discovery
  continues; signing always requests fresh state and live proofs.
- Give only the read-only covenant-holdings command a bounded two-minute UI
  deadline instead of the ordinary 30-second review deadline. Other review,
  authorization and auto-lock policies are unchanged.
- Reproduce and fix the Kaspire token display issue: 0.5.26 withheld its positive
  result until a 92-token scan finished. The delivered 0.5.27 ZIP displayed
  **0.59973229** tokens in approximately **two seconds** with live read-only
  responses in Chromium. This measurement is not a guaranteed provider latency.

## Browser extension verification

- **264 unit/WASM tests** and TypeScript passed, including native covenant
  execution for both pinned standard configurations and invalid-state rejection.
- Packaged-Chromium checks passed early balance publication, a stalled later
  standard query, reopening/replay, post-30s results and request coalescing.
- Actual Chrome Side Panel approvals, explicit signing/rejection, wrong-password
  recovery, timed expiry, close cancellation and popup fallback passed.
- Full Chromium smoke, four-theme/narrow-layout, progressive Activity, NFT/Nexus
  and swap navigation checks passed. ZIP integrity, extension identity, exclusion
  of source maps/server-only credentials and public readiness were checked.
- Update the existing extension rather than uninstalling it. ZIP publication
  does not establish Chrome Web Store approval or rollout of 0.5.27.

## Android verification

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

Browser extension:

- [Extension 0.5.27 ZIP](https://kaspire.kaslab.space/downloads/kaspire-extension-0.5.27.zip)
- SHA-256: `5ad1460e1787211ba1699d8252bfb700a6a9ecd4044a2f269fa43e21ed2980c9`
- [Full extension release](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/extension-v0.5.27)
- [Source comparison: 0.5.23 → 0.5.27](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/extension-v0.5.23...extension-v0.5.27)
