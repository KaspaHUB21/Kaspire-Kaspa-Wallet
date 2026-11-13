# Kaspire Extension 0.5.30 — Native KCC20 dApp payments

Changes since the public extension 0.5.29:

- Selected KCC20 payments have a separate, bounded, paced read lane. A slow
  wallet discovery/history scan no longer holds up payment preparation.
- Preparation resolves the requested token, verified units, current signing
  cells and own-node proofs. Cached display units do not override fresh units.
- A cancellable preparation screen shows progress in the side panel or approval
  window. Preparation cannot authorize signing; explicit transaction review is
  still required. Cancellation and late results never sign or send tokens.
- Pinned reference KCC20 transfers use the complete native payment plan even
  when only one transaction is needed. Necessary self-consolidations and the
  final recipient payment are reviewed together, signed once and saved before
  broadcast. Confirmed steps are checkpointed and recorded in activity.
- Borrowed Receive reuses an eligible recipient cell. An unavailable lookup
  stops preparation instead of silently funding another cell.
- The plan review shows KAS locked in token cells, necessary reserve top-ups,
  returned KAS and total network fees separately. Approval windows now adapt to
  narrow widths in every theme instead of retaining the fixed popup width.
- An uncertain signed payment remains recoverable in Send assets. A saved plan
  blocks duplicate preparation. Only the final recipient transaction ID is
  returned to the dApp.

Platform scope: this ports the applicable Android 0.11.106 native reference
KCC20 payment behavior. Existing extension discovery, images, exact units,
history paging and fallback handling remain unchanged. Approval presentation
uses Chrome windows/side panels instead of Android dialogs. Existing separate
KRON, KaspaRocket, Kasseal and legacy signing policies are not broadened. No
Android, iOS PWA, GothDAG, native signing binary, permission or public update
channel is changed. This ZIP is not a Chrome Web Store approval or publication.

Validation (2026-11-13): TypeScript check; 295 passing unit/native-WASM tests
(six pre-existing skips); Chromium wallet/security smoke; the extracted ZIP's
actual dApp flow, both approval surfaces, four themes at 390px, cancellation
and late results, Borrowed Receive, full-plan signing, durable checkpoints,
confirmation interruption/reopen/recovery, duplicate-payment blocking and
activity recording. Slow discovery, reopening and post-30-second results passed
in both wallet and panel layouts. No real payment was made. The extension key,
permissions, native WASM and DEX engine match public 0.5.29 exactly.
