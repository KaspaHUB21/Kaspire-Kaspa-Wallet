# Kaspire Android 0.11.107 & Browser Extension 0.5.31

2026-11-13. Android build **255**, cumulative since Android **0.11.106 (254)**.
Extension **0.5.31** is the unchanged published ZIP; its complete cumulative
changes since extension **0.5.29** are included below, including 0.5.30.

## Android 0.11.107

### Toccata PSKT compatibility and actionable errors

- The rebuilt native core accepts redeem scripts up to **64 KiB**, including
  the reported **56,899-byte** fee-holder unwrap size. Empty/larger scripts
  still fail closed before hex decoding. The 256-KiB serialized script-request
  total, 512-KiB transaction JSON and other witness/data bounds are unchanged.
- Both Android JNI preparation and signing preserve strict schema validation
  diagnostics from the shared native parser: unknown field names, wrong types,
  and line/column information. The app also identifies malformed public-envelope,
  options and selected-input fields instead of reporting a generic request error.
- Legacy and normalized `signPskt` response shapes remain compatible. Script
  fields are passed intact to native strict validation. Explicit review,
  business-rule warnings, review-hash binding and fresh authorization remain.
  `signPskt` is sign-only: it never submits a transaction for the dApp.
- A synthetic unwrap-shaped regression fixture exercises real signing and
  Toccata VM execution, invalid signatures, changed reviews and size boundaries.
  It is not KaspaCom's production contract; their exact integration fixture is
  still needed to validate their contract-specific business rules.

### Native KCC20 payments

- Selected-token preparation and recipient-cell checks now use a separate,
  bounded, paced read lane shared across payment-service instances. An active
  background discovery or history request no longer holds payment preparation
  behind its network timeout. Public discovery remains independent and paced.
- Retains 0.11.106's selected, pinned-reference payment flow: fresh token units,
  live own-node signing-cell proofs, cancellable progress, explicit review of
  the complete immutable plan, necessary self-consolidation and final payment.
- Borrowed Receive reuses eligible recipient cells and fails closed when their
  lookup is unavailable. Reserve top-ups, released KAS and total network fees
  remain separate. Signed bytes are saved before broadcast; accepted steps are
  checkpointed and recorded in activity. Existing signed plans block duplicate
  preparation and can be continued through Send assets. Only the final recipient
  transaction ID is returned, never an intermediate self-consolidation ID.

### KaspaCom NFT trait filters

- Checked JEETSLIFE against all **7,777** locally cached NFT metadata records
  and all **39** current supported PSKT listings. Those listings contained
  **275** distinct trait values in **12** categories. Every one was present in
  the app's API. The complete collection contained **1,237** values in **13**
  categories; values without current PSKT listings are intentionally absent.
- Adds an explicit explanation that filters cover currently listed PSKT NFTs,
  not unlisted NFTs or old escrow listings. No escrow signing support is added.
- Verified that a menu with **200** values can scroll to and select its last
  value at 320px in every Android theme, and sends that exact trait filter.

## Browser Extension 0.5.31 — cumulative since 0.5.29

### Native KCC20 dApp payments (included from 0.5.30)

- Separate bounded, paced payment reads prevent slow discovery/history scans
  from delaying a selected payment. Fresh verified units override display caches;
  current signing cells are independently checked against the own node.
- Cancellable preparation shows progress in ordinary approval windows and
  Chrome's matching side panel. Cancellation, rejection and late source results
  never authorize, sign or send a payment.
- Pinned-reference transfers always use the complete native payment plan, even
  for one transaction. Necessary self-consolidations and the final recipient
  payment are reviewed together, signed once, durably saved and checkpointed.
- Borrowed Receive reuses eligible recipient cells; unavailable lookups stop
  preparation rather than silently fund another cell. Reviews separate cell
  reserves, reserve top-ups, returned KAS and total network fees.
- Signed uncertainty stays recoverable in Send assets, blocks duplicate
  preparation, and records each confirmed step once. The dApp receives the
  final recipient transaction ID only.
- Approval windows fit narrow widths in every theme. Existing progressive
  discovery, exact units, images, history paging and fallback handling remain,
  including late positive results and reopening after ordinary UI deadlines.

### Toccata PSKT integration (0.5.31)

- The native WASM signer supports the same bounded 64-KiB per-script limit and
  56,899-byte regression size, with strict total/request/witness bounds.
- Preparation and signing return original strict JSON schema diagnostics.
  Unknown fields are still rejected; no schema or signing policy is relaxed.
- The synthetic fixture covers review, signing, native VM execution, invalid
  signatures, changed reviews, nested schema errors and oversize rejection.
  No generic PSKT broadcast or new trusted covenant profile is introduced.

## Platform scope, delivery and validation

- Android keeps package `space.kaspire.wallet`, the release certificate and
  signing lineage, both `arm64-v8a` and `armeabi-v7a`, permissions, wallet data
  and update trust. Build 255 upgrades public build 254 without reinstalling.
- **Both update routes** publish the identical signed APK: the official website
  download and the GitHub Release used by the signed in-app updater. Website
  version/checksum, signed manifest and GitHub assets agree. This combined release
  also includes the unchanged extension ZIP and checksum.
- Android uses native dialogs; the extension uses its popup or matching side
  panel. Existing separate KRON/KaspaRocket/Kasseal signing policies are not
  broadened. Kasseal Borrowed Receive remains excluded; Android's typed dApp
  KCC20 method remains limited to the pinned reference programs.
- **171 native Rust tests** passed, including actual Toccata VM signing;
  **238 Flutter tests** passed with three existing skips, covering PSKT review,
  cancellation, selected payment reads, retained/partial discovery, recovery,
  both updater choices and long trait menus in every theme. Package checks
  verify the actual APK's native libraries, ABI/export identity, client
  configuration, permissions and signature. No live funds are used by tests.
- Extension 0.5.31 previously passed **298 extension/WASM tests** (six existing
  skips), TypeScript checks, and actual extracted-package Chromium provider,
  popup/side-panel, four-theme narrow-layout, delayed discovery and payment
  recovery regressions. Its already-published bytes are not rebuilt here.
- No physical Android-device test is claimed. KaspaCom's exact production
  unwrap fixture remains outstanding. iOS at `ios.kaspire.me`, Windows and
  unrelated in-progress marketplace purchase/recovery changes are excluded.
- A published ZIP is not Chrome Web Store approval. Store rollout is separate.

Android APK SHA-256:
`0de7a746420421c0d9408605a1e629fa91813fe37d50ec7e0657201111b40f0e`

Extension 0.5.31 ZIP SHA-256:
`cb4c1ea8cd4a21cc650b2d07906f4ec9847c5c51bba5bd1f7b022cb20f52dedd`
