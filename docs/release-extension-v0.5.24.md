# Kaspire Extension 0.5.24 — Activity and optional Side Panel

- Add a split-window button to the upper header. It opens the wallet in
  Chrome's side panel beside the current webpage. The normal popup remains
  default; nothing opens automatically. The panel has the same wallet UI,
  themes, native signing and approval checks, with responsive width and height.
- Add the Chrome `sidePanel` permission without adding any host permissions.
  Closing the last wallet view still enforces Immediately auto-lock; closing a
  popup alone no longer locks an already open panel.
- Load Activity sources independently: native KAS, directly queried KRC20,
  exact KRON token quantities, NFT/name receipts, legacy covenant movements,
  locally saved transactions and targeted standard KCC20 receipts.
- Display the latest 50 merged entries, then another 50 with Load more. A
  stalled asset source does not prevent healthy transactions from appearing
  or prevent native-history pagination. Partial/failed sources preserve loaded
  rows, report incomplete coverage and can be retried.
- Resolve standard KCC20 history from native covenant references and discovered
  token outputs instead of scanning global trading history. Cache immutable
  complete receipts; prioritize Activity while keeping shared pacing and 429
  backoff. Incoming and outgoing quantities are calculated with integer units.
- Paginate native history using requests of at most 100 rows. Reject malformed
  responses and use the independent read-only fallback. Preserve healthy HD
  address results when another address fails.
- Use the persistent own-server KRC20 logo cache in progressive holdings and
  token details, independent of market-enrichment completion. Already cached
  images survive upstream outages; first-time misses still need an available
  original image.
- Keep long token names and transaction labels inside narrow cards. Token
  amounts and labels use separate lines where appropriate; signing values
  remain canonical and ungrouped.

## Verification

- 246 extension unit/WASM tests and TypeScript checks pass.
- The real Chromium extension smoke covers onboarding, encrypted backups,
  worker restart, private P2SH routing, dApp connection/signing, stale approvals,
  pending-reveal recovery, timed expiry and shared popup/panel auto-lock.
- Headful Chromium opens an actual `SIDE_PANEL` context only after an explicit
  user gesture, keeps the normal popup default and closes the panel explicitly.
- Browser layout checks cover four themes at 320 px, aligned header buttons,
  long names, and 50/100/121 Activity rows while another source is stalled.
- Read-only `goatmilk.kas` checks returned KAS and KRC20 rows in under one second,
  38 targeted standard KCC20 entries without warnings in approximately 19 seconds,
  and healthy KRON, NFT/name and legacy source responses. These are server-side
  observations, not guaranteed timings on every user's device.
- No consensus, signing-template, provider-permission or broadcast changes.
  No transaction was broadcast for these checks. Windows and Android packages
  are unchanged by this extension build. Chrome Web Store submission remains
  a separate publisher action.

Store ZIP SHA-256:
`6f576b4b679d382dcfb2b5e7838a8fcabfe82bb678fdb97c29c382a4b348bcbe`
