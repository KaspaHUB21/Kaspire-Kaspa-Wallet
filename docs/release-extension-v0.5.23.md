# Kaspire Browser Extension 0.5.23 — Kasseal Mainnet and recovery

Complete extension release notes for the update from **0.5.21 to 0.5.23**,
including the Kasseal integration introduced in 0.5.22 and its 0.5.23 recovery
hotfix.

## Kasseal Mainnet

- Add Kasseal DEX to Mainnet Swap. The order is now **KaspaRocket → Kasseal DEX → KRON**, using the official Kasseal logo.
- Support bonding-curve buys and sells with exact whole-sompi pricing and 1,000-token lots. Unspent KAS remains in the wallet.
- Support constant-product pool buys and sells after graduation, with any whole number of tokens rather than curve lot restrictions.
- Verify launch proofs through the pinned SDK 0.1.1 unsigned planner and validate supported contracts through the shared local Rust/WASM core.
- Review token and market covenant identities, trade limits, slippage, deposits, wallet flows and network fees before signing. Verify current input amounts, scripts, covenant IDs and DAA data against the own node, and recheck inputs after approval.
- Execute the signed covenant scripts locally before returning signed transactions. Provider SDK credentials remain server-side; no remote signing code or private signing key is sent to the planner.

## Token discovery and search

- Load Kasseal wallet holdings independently of the other token indexers, directly into the wallet's KCC20 assets. Opening Swap is not required for discovery.
- Search the **complete Kasseal catalogue** by ticker or name, not just the first 20 loaded results. This includes tokens such as UNNACHOD outside the initial page.
- Resolve exact covenant-ID searches directly and open held tokens even when they are absent from the first catalogue page.
- Debounce search, ignore stale responses/errors from earlier queries, reset pagination when the query changes and keep each Load more request bound to its query.
- Deduplicate paginated results by covenant ID and retain verified-token/image requirements.
- Keep independent holdings visible when another data source fails. Unavailable balance data is not displayed as a zero balance.

## Token preparation, confirmations and activity

- Support separately reviewed, self-owned token-cell **split and merge** preparations needed for partial sales or fragmented holdings.
- Clearly distinguish preparation from the actual trade. Confirm the preparation on the own node and wait for Kasseal indexing before requesting a fresh quote and review for the next step.
- Do not label a preparation as a completed sale or add it as Buy/Sell token activity.
- Display trade proceeds separately from refundable token-cell deposits, protocol fees and network fees. Show the net wallet KAS change without counting large funding-change outputs as income.
- Show confirmed Buy/Sell receipts, a return-to-marketplace action, transaction-ID copying and a separate **My activity** tab.
- Record confirmed Kasseal token activity as well as the associated KAS transaction. The Kasseal history tab contains swaps recorded on this wallet/device, not a complete cross-wallet trading history.

## Saved-swap recovery — 0.5.23 hotfix

- Fix `Invalid saved swap input`: accept both the Rust SDK's **flat SafeJSON outpoints** used by Kasseal and the **nested RPC outpoints** used by Rocket.
- Reject malformed, ambiguous, out-of-range and duplicate input identities before using them as evidence of a conflicting spend.
- Preserve signed swaps inside the encrypted wallet before the first submission. Recovery submits only the same saved transaction bytes; it does not silently sign or create a replacement.
- Keep existing 0.5.22 pending swaps compatible without changing their signed bytes or requiring a recovery-data migration.
- Submit freshly signed, live-node-verified Kasseal transactions without a redundant pre-submit history scan.
- Archive an obsolete swap only after the own node confirms a competing transaction spending an exact saved input, with a final recheck of the original transaction. Missing transactions, timeouts or incomplete history alone do not authorize discarding it.
- Refresh the UI after a proven obsolete swap is archived so the user can request a fresh quote again.
- Preserve recovery during unknown confirmation status, interrupted submissions and delayed preparation indexing.

## KaspaRocket assets and transfers

- Open Rocket tokens in an asset detail view showing the image, ticker, balance, price per complete token and balance value instead of immediately opening Swap.
- Provide separate **Send Asset** and **Swap** buttons.
- Resolve transfer cells using Rocket holdings as hints, the pinned reference **10-input/10-output** program and live own-node proofs, without requiring Kasvio to discover those cells first.
- Keep local transaction reconstruction and covenant execution checks. More than ten required token cells use the existing reviewed consolidation/payment-plan flow rather than relaxing template limits.
- Correct Check on Explorer links to `https://kaspatoken.kaslab.space/kcc20/<covenantId>`.

## P2SH, dot.k and presentation

- Add paginated P2SH account history, transaction deduplication, Load more and an explicit incomplete-history indication instead of silently stopping at the first 50 transactions per address.
- Extend saved Rocket swap conflict checks beyond the former three-address/first-page limits with bounded pagination and explicit unknown-status handling.
- Add the default **Newest listings** sort and expandable dot.k name-length filters: 1–3, 4–6, 7–9 and 10+ characters, applied to the directory query rather than only loaded rows.
- Restore verified KCC23 token declarations for display where available, without changing covenant identity or signing templates.
- Improve exact US-style thousands separators and decimal points in token, swap, P2SH and vault displays. Raw signing and amount-entry values remain ungrouped.
- Correct Kasseal/KRON amount-field spacing and Kasseal two-tab alignment. Keep forms, reviews and buttons consistent with the selected theme.

## Validation and upgrade

- **232 automated regression tests passed.**
- Actual Rust/WASM curve-buy, pool-buy, pool-sell, split and merge fixtures are signed and locally executed using public synthetic keys/outpoints; their real SafeJSON is also passed through the recovery parser.
- Chromium checks cover Kasseal navigation, global/racing search, pagination, balances, review, receipt/history, obsolete-swap UI recovery and Rocket asset details/explorer links across Midnight, HUB21, Glacier and Neptune.
- The full extension Chromium smoke test passed, including onboarding, backups, worker restart, dApp connection/signing, stale approvals, timed locking and secret-isolation checks. Separate P2SH theme/navigation checks were also completed.
- Mainnet catalogue/command checks were read-only. No funded wallet was signed or broadcast as part of this verification.
- The extension name, extension identity, permissions model and existing wallet storage are preserved, with the additional specific Kasseal API host permission. The package name contains no “test” label.
- **Update the existing extension rather than uninstalling it.** For a saved swap, use its status/recovery action before creating another trade. Wallet backups remain important.
- This is an extension release; the Android APK and its signed update channel are unchanged. ZIP availability does not mean Chrome Web Store review/rollout has finished.

## Download verification

- Package: `kaspire-extension-0.5.23.zip`
- SHA-256: `698cccc0500fbdb7a0de5f7480fd745be140a5287975f9b86d803b9e3662a75b`
- [Download the extension ZIP](https://kaspire.kaslab.space/downloads/kaspire-extension-0.5.23.zip)
- [Source comparison since 0.5.21](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/extension-v0.5.21...extension-v0.5.23)
