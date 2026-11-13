# Kaspire Extension 0.5.31 — Toccata PSKT integration

## New in 0.5.31

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

## Also included since public extension 0.5.29

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
