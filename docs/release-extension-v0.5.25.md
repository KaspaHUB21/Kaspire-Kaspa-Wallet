# Kaspire Extension 0.5.25 — dApp approvals inside the Side Panel

Corrects the initial Side Panel integration in 0.5.24. Previously the wallet
could be displayed beside a webpage, but dApp approval requests still always
opened an external window.

- Route dApp connection, unlock and signing reviews into the open Side Panel
  belonging to the requesting browser window. The existing approval function
  covers transaction and multi-step inscription reviews as well as messages.
  The ordinary popup remains the fallback without a matching open panel.
- Use the existing themed approval UI, including transaction details and raw
  JSON. Locked wallets can unlock inside the panel, with visible wrong-password
  feedback and password visibility control. Unlocking alone does not sign.
- Preserve native transaction review, review-hash binding, session-generation
  and account/network checks. Check session expiry again before accepting a
  panel decision. No transaction-signing or broadcast implementation changes.
- Serialize panel approvals, match decisions to exact pending IDs and reject
  requests when their presenter closes. Old/unknown IDs cannot approve another
  request. Generic approval-popup messages cannot resolve panel-owned reviews.
- Validate the packaged sender and a unique per-view document against Chrome's
  real `SIDE_PANEL` contexts. This supports Chrome versions that omit sender
  document IDs and report the panel's context window ID as -1. Ordinary tabs
  are not approval presenters. Preserve the original caller's browser window
  across multi-stage requests; never guess between ambiguous caller windows.
- No heartbeat, passive activity timestamp update or auto-lock override.
  Existing Immediately and timed auto-lock behavior remains in force.

## Verification

- 255 extension unit/WASM regression tests pass, including context verification,
  FIFO presentation, matching IDs, rejection, close cancellation, Chrome's
  missing-ID case, wrong-window fallback and absence of heartbeat/lock overrides.
- TypeScript checks pass.
- A freshly generated unfunded wallet in actual headful Chromium confirms dApp
  connection and message consent/rejection inside an actual `SIDE_PANEL`,
  synthetic native PSKT transaction review/rejection, locked-wallet unlock with
  wrong-password recovery, timed-expiry rejection, close cancellation, and the
  normal popup fallback after the panel closes. No transaction is broadcast.
- The existing full extension smoke and four-theme/narrow-panel layout checks
  cover popup operation, private wallet commands, worker restart, encrypted
  backup, stale approvals, shared-view auto-lock and Activity pagination.

Android, Windows and the public release/update channels are unchanged.
