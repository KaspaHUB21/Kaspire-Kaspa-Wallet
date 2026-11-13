# Kaspire Android 0.11.106 & Browser Extension 0.5.31

Combined release notes, backfilled on 2026-11-13. The Android 0.11.106 APK
and extension 0.5.31 ZIP are their existing, unchanged public artifacts.
The extension section includes all changes since extension 0.5.29.

## Android 0.11.106 (254)

2026-11-13. Complete cumulative changes since public Android **0.11.105 (252)**.
Includes the user-approved KCC20 dApp fix from **0.11.106-test.1 (253)**.
Public Android build: **254**.

### Native KCC20 payments from dApps

- Updates KCC20 requests. The old handler scanned the entire wallet and expected discovery results to already contain verified
  signing cells. Current discovery deliberately resolves signing cells only when a specific transfer is prepared.
- Resolves only the requested, pinned reference KCC20 covenant, verifies its
  token units and current spendable cells, and prepares the complete native
  transfer plan. No full-wallet, price or unrelated token-history scan is
  required before approval.
- Shows a cancellable preparation dialog with progress before the explicit
  transaction review. Cancelling or rejecting does not sign or send tokens.
- Reuses an eligible recipient token cell with Borrowed Receive. An unavailable
  recipient lookup fails closed instead of silently funding an unnecessary new
  cell. Necessary self-consolidation uses the existing native payment planner.
- Saves the immutable signed plan before broadcasting, checkpoints confirmed
  steps, and supports continuation through Send assets. An existing saved
  payment blocks preparing a duplicate. The dApp receives the final recipient
  transaction ID, never an intermediate self-consolidation ID.
- Records each confirmed transfer in wallet activity. Uncertain signed-payment
  outcomes explicitly instruct users to check the dApp and the saved transfer
  rather than pay again.

### Delivery and validation

- Preserves the Android package, release certificate and signing lineage, both
  `arm64-v8a` and `armeabi-v7a`, native signing libraries and Android permissions.
- Preserves **both update routes**: the classic official-website APK download
  and the identical GitHub Release APK used by the signed in-app updater.
  Website version/checksum, release assets and signed manifest refer to the
  same public artifact. Build 254 upgrades both public build 252 and test 253.
- Repeats 100 focused dApp, KCC20 discovery, fallback, payment-journal and update
  tests, static analysis, and checks the actual built APK's two architectures,
  client configuration, signature, package identity and download hashes.
  Automated tests use isolated fixtures, not real user payments.
- Browser Extension **0.5.29**, iOS/React PWAs, Windows and unrelated in-progress
  marketplace/server changes are excluded from this Android release. This
  release does not change GothDAG's confirmation polling or its local indexer.
- Website download cards retain version, download and checksum; complete
  release notes remain on GitHub.

Verified Android APK SHA-256:
`7d458ba94b355e9dfc6ddff526960714bcb79cbf7f8dfa278e15bda0326f1142`

## Browser Extension 0.5.31

### New in 0.5.31

- Normalized `signPskt` supports redeem scripts up to 64 KiB, including the
  reported 56,899-byte Toccata fee-holder unwrap size. Larger and empty scripts
  still fail closed, with a size check before hex decoding. The 256-KiB
  serialized script-request total, 512-KiB transaction JSON and other
  witness/data limits remain.
- Native WASM `preparePskt` and `signPskt` preserve strict JSON schema validation
  diagnostics, including unknown field names, incorrect types and line/column
  details. Unknown fields are still rejected; schema validation is not relaxed.
- A compact synthetic fee-holder unwrap-shaped regression fixture exercises
  review, signing, Toccata VM execution, review binding, invalid signatures and
  boundary rejection. It is not KaspaCom's production covenant. Their exact
  unsigned integration fixture is needed to validate their business rules.

### Also included since public extension 0.5.29

- The native KCC20 payment improvements delivered in 0.5.30: a separate bounded
  payment read lane, cancellable preparation in popup/side panel, fresh verified
  token units and own-node cell proofs, complete immutable payment plans,
  Borrowed Receive with fail-closed lookup, checkpointed recovery and activity.
- Approval windows adapt to narrow widths in every theme, with separate KAS
  reserve, returned-KAS and network-fee details. Interrupted signed payments
  block duplicate preparation and remain recoverable from Send assets.

Scope: extension ZIP only. Extension identity, permissions and signing approval
controls are preserved. Unknown-contract business-rule warnings remain. Native
WASM is rebuilt for the two PSKT fixes; no new covenant profile is trusted.
No transaction is sent by `signPskt`. Android/iOS/Windows builds and their update
channels remain unchanged. The extension ZIP and checksum are published on the
website and in the extension's GitHub release. Chrome Web Store approval and
rollout are separate; the Store can still serve an earlier approved version.

Validation (2026-11-13): 171 native Rust tests; 298 passing extension/WASM tests
(six pre-existing skips); TypeScript and syntax checks; actual Chromium provider
review/signing of the 56,899-byte normalized fixture with exact transaction
preservation, unchanged business-rule warnings, nested schema diagnostics and
oversize rejection. The extracted ZIP also passed native KCC20 payment,
Borrowed Receive, cancellation, multi-step recovery/activity, side-panel,
four-theme narrow-layout and delayed-discovery regressions. No real funds were
used or broadcast. KaspaCom's exact production unwrap fixture is still pending.

Downloads: the Android APK and signed update manifest are attached to this
release; the extension ZIP and checksum are attached to the
[extension-v0.5.31 release](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/extension-v0.5.31).
Chrome Web Store review/rollout remains separate.
