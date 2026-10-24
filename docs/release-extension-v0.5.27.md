# Kaspire Browser Extension 0.5.27 — Side Panel, Borrowed Receive and reliable balances

Complete cumulative changes from **0.5.23 to 0.5.27**, including the work prepared
in 0.5.24, 0.5.25 and 0.5.26. Android is published separately as **0.11.67**.
Windows is unchanged. The extension remains **Kaspire Wallet**, with the same
Chrome Web Store identity and existing encrypted wallets.

## Optional Chrome Side Panel

- Add a split-window button to the header. Open Kaspire beside the current
  webpage, and close it with that button where supported or Chrome's close
  control. The ordinary popup remains the default; no automatic panel opening.
- Use the same packaged wallet and native Rust/WASM core in popup and panel,
  adapting to the available width/height across all themes. Keep long token
  names and operation labels within their frames, with full details available.
- Add the specific `sidePanel` permission, without new website host permissions.
  Chrome may request approval for the extension permission change.

## dApp approvals inside the panel

- A matching open panel in the requesting browser window presents connection,
  unlock and signing reviews instead of opening separate approval windows.
  Without a matching panel, retain the ordinary popup approval flow.
- Verify the actual Chrome `SIDE_PANEL` document context. An ordinary tab opening
  `sidepanel.html` is not an approval presenter. Never send reviews to a different
  browser window or guess between ambiguous requesters.
- Queue requests and bind decisions to the exact pending ID. Closing the panel
  rejects unanswered approvals. Session expiry, account/network checks, review
  hashes and native signing checks remain enforced. Unlocking does not sign;
  explicit approval/rejection and wrong-password recovery remain separate.
- No heartbeat or auto-lock override. Closing a popup does not lock a still-open
  panel; Immediately auto-lock still locks when the last wallet UI closes.
  Timed session expiry is unchanged.

## Activity parity, logos and asset presentation

- Load KAS, KRC20, KRON, standard KCC20, legacy covenant, NFT/name and saved
  activity independently. Slow discovery cannot hold the entire timeline back.
  Source failures retain loaded entries, mark incomplete coverage and offer Retry.
- Start with the latest **50 merged entries**; Load more adds 50. Use bounded
  native/KRC20 pagination and deduplication rather than rendering hundreds at once.
- Read KRC20 history directly via Kasplex with a fallback. Keep internal decimal
  values canonical and apply thousands separators only for display.
- Resolve standard KCC20 history from exact wallet-related receipts, not global
  trading feeds. Cache complete details, coalesce requests and prioritize targeted
  history reads while preserving shared pacing and HTTP 429 backoff.
- Prefer verified KCC20 units, including Rocket's three decimals when genesis
  metadata omits them. Verified receipts override legacy fallback amounts for the
  same transaction/covenant identity. Unknown units are raw, not assumed eight.
- The reported BTE transaction's `250000` raw units are **250 BTE**, not the old
  eight-decimal fallback display. This changes history display, not chain amounts.
- Load KRC20 logos through Kaspire's persistent server cache before market
  enrichment finishes. Saved logos survive upstream failures; a first fetch of
  an uncached image still requires a working original source.

## Borrowed Receive for standard KCC20 and KaspaRocket

- Reuse an eligible live recipient cell when its amount-threshold policy permits
  the incoming increase. Preserve its owner, entire guard, extended identity,
  existing tokens and KAS deposit. Sign sender inputs only, not the borrowed input.
- Check recipient state against accepted own-node outputs and live UTXOs. Native
  deterministic rebuilding, review binding and local covenant VM execution remain
  mandatory. Do not forge a signature or bypass a disabled/authorized policy.
- Send existing owner-authorized standard cells carrying receiving policies.
  New standard receiving/change cells permit future positive borrowed receipts.
  Signature/hash-chain receiving policies are not permissionless and are not
  automatically consumed.
- Respect the pinned 3/3 or 10/10 limits. Reserve the recipient input slot; borrow
  only in the final payment, not in preceding sender self-consolidation steps.
- Review whether a cell is reused, none is eligible, or optional discovery was
  unavailable. In the latter cases create a new receiving cell rather than spend
  unverified recipient data.
- **Kasseal and legacy KRON production paths remain unchanged.** Borrowed Receive
  is not newly enabled through these separate transfer/swap integrations.

## Cause reproduced

The actual 0.5.26 ZIP was loaded in fresh Chromium with the affected public
address as a watch-only wallet. Kasvio returned the correct positive balance on
the second token balance request, but the extension withheld it until the full
92-token scan finished roughly 30 seconds later. The UI also stopped waiting at
30 seconds. Android already publishes positives within its discovery loop.

## Fix

- Publish each validated standard KCC20 holding immediately, independently of
  subsequent balances and legacy indexers. Keep shared request pacing/backoff.
- Reopened/concurrent views receive already found holdings from the active scan
  without launching a second scan. Per-view listener failures do not affect it.
- Keep partial results separate from the completed holdings cache. Selecting an
  already displayed token can use its discovered display metadata; native
  signing continues to request and validate fresh state.
- Use a bounded two-minute timeout for this read-only holdings command only.
  Other review timeouts, authorization, session expiry and signing are unchanged.
- This balance-specific fix does not change Kasseal production paths or Android;
  the separate Android 0.11.67 release includes the shared changes listed above.

## Verification

TypeScript and 264 unit/WASM tests passed. The dedicated packaged-Chromium
regression checks a positive balance before a blocked later standard request,
reopening with replay, another positive arriving after the old 30-second limit,
and one coalesced discovery scan. The holdings browser fixtures use public watch-only
addresses and synthetic read responses; no transaction is signed or broadcast.

Both Chromium runs passed against the exact delivered ZIP. With live read-only
responses for the reported public receiving address, the Kaspire holding appeared
as **0.59973229** in approximately **2.0 seconds**, instead of waiting for the
full catalogue scan. The regression also passed reopening, a blocked standard
balance, post-30s progress and request coalescing. The actual Chrome Side Panel
opt-in/default/size/close regression passed. ZIP integrity and TypeScript passed.
The exact build is promoted without changing its bytes. Chrome Side Panel,
in-panel connection/unlock/signing approvals, timed expiry, rejection/close
cancellation, popup fallback, theme/navigation and full Chromium smoke regressions
passed before publication. The shared native core has **134 passing tests**.
No funded wallet or real financial transaction is used for verification.

## Update and downloads

Update the existing extension rather than uninstalling it. Keep an up-to-date
encrypted wallet backup, including saved P2SH state/pending transactions. ZIP
publication is separate from Chrome Web Store review/rollout and does not establish
that the Store already serves this version.

- [Extension ZIP](https://kaspire.kaslab.space/downloads/kaspire-extension-0.5.27.zip)
- [Source comparison: 0.5.23 → 0.5.27](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/extension-v0.5.23...extension-v0.5.27)

ZIP SHA-256:
`5ad1460e1787211ba1699d8252bfb700a6a9ecd4044a2f269fa43e21ed2980c9`
