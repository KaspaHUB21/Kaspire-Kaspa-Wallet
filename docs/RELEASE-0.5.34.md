# Kaspire Browser Extension 0.5.34

2026-11-24. Cumulative changes since public extension **0.5.32**. Includes the
native-swap and Cosmic work from the unreleased 0.5.33 review package.

## Native KAS / kUSDT swaps

- Adds **KAS / kUSDT** as the first Swap entry, above the other DEXes. Buy and
  sell through Trestly KasPool directly inside Kaspire on Kaspa Mainnet, without
  opening a dApp, connecting a separate session or bridging to another network.
  kUSDT remains the bridge-backed asset issued through Trestly.
- Uses pinned token/pool identities, compiled locking scripts and the same
  local transaction builder as Android 0.11.122. Independently verifies live
  inputs and pool state; review binds direction, debit, receive amount, fee
  limit and pool state. Explicit wallet approval and local script execution
  remain mandatory. This does not broaden generic dApp signing permissions.
- Displays available kUSDT and **MAX** with exact six-decimal units. Failed or
  incomplete discovery is not displayed as a verified zero. With fragmented
  holdings, the verified total and maximum per swap are shown separately: this
  profile spends one token UTXO per sell, so MAX selects the largest verified
  spendable cell. No automatic consolidation is added.
- Uses Kaspire's dedicated exact-wRPC route, forwarding the original signed
  transaction to the fixed own node without wallet-SDK conversion, altered
  witnesses, edited outputs or automatic send retries.
- Saves signed swaps before submission. Recovery checks the exact transaction
  and mempool before resending the same bytes. Unknown/rejected results preserve
  the signed journal and show a bounded error; a submission acknowledgement is
  not treated as confirmation and no replacement swap is silently created.
- Includes native swap recovery data in encrypted extension backups and keeps
  previous and current swap receipts clearly separated. The requested
  audit-status sentence is omitted from the swap footer; the bridge-backed
  asset and Kaspa-L1-only explanations remain.
- Build tooling invalidates the wallet and pool crates' cached WASM outputs.
  The pool core is loaded with a build-bound checksum to reject mixed packages.

## Cosmic theme

- Adds **Cosmic** under Settings → Wallet display → Kaspire design, persisted
  by theme name without changing the default or existing preferences.
- Includes Android's space artwork, violet/cyan neon surfaces, detailed
  nebula/starfield action buttons and a planetary-horizon navigation bar.
- Keeps the balance-card planet round at different widths and removes the
  logo from the planet. Styles wallet, swap and approval surfaces in both the
  action popup and Side Panel, retaining the extension's existing navigation.

## Currency selection fixed

- Fixes the actual selection handler: automatic text formatting previously
  changed `EUR` to `Eur` (and other codes similarly). Options had no explicit
  values, so the background silently ignored the resulting invalid value.
- Uses shared canonical codes and explicit option values for all eleven
  supported currencies. Monetary symbols/codes retain their correct casing.
  Invalid requests now report an error instead of appearing to succeed.
- Shows saving feedback, updates the display after saving and preserves the
  preference independently of stale wallet-state writes. Reopening screens,
  closing the popup/panel, locking and restarting the browser retain the choice.
- A failed exchange-rate read does not reset the preference to USD. A delayed
  settings save cannot replace a later send or approval screen.

## Platform differences and scope

- Uses a separate pinned Rust WASM instance instead of Android JNI/keystore,
  sharing the local builder while preserving the existing wallet core. Native
  signing is authorized through the extension's popup or matching Side Panel;
  unlocking alone does not authorize a swap.
- The native pool is Mainnet-only and wallet-internal. MAX remains limited to
  one verified token cell. Cross-platform pending-journal import is not claimed.
- Cosmic adapts the existing desktop actions/navigation; no Android-only
  embedded browser or pairing action is invented.
- Other Android-only changes and later Explorer/Glacier work are outside this
  extension update. Android, iOS PWA and Windows channels remain unchanged.

## Verification and delivery

- The 0.5.33 review build passed 309 extension/WASM tests with six optional
  fixture skips, TypeScript checks and packaged Chromium regressions.
- The final 0.5.34 package passes TypeScript checks and **277 tests**, with
  zero failures and six optional captured-fixture skips. P2SH and covenant-vault
  Cargo/native-fixture suites were not rerun for this UI correction; their
  previously checked native assets are retained byte-for-byte.
- Actual packaged action-popup and Side Panel tests select all eleven
  currencies through the real UI handler and verify conversion, screen reentry,
  closure, stale snapshots, delayed saves, exchange-rate failures, lock/unlock
  and a complete browser/worker restart.
- Packaged regressions cover native buy/sell and local script execution,
  explicit/rejected approvals, exact MAX, partial/failing/slow/zero/fragmented
  discovery, stale state/clock rejection, same-byte recovery, responsive Cosmic
  and other theme layouts, onboarding, L2/backup, provider/PSKT review, timed
  locking, Side Panel approvals and late/reopened KCC20 holdings.
- Native WASMs, DEX runtime and static/theme assets match the checked 0.5.33
  package byte-for-byte. Extension identity is preserved. Compared with public
  0.5.32, native swaps add the narrow `https://api.trestly.io/*` host permission;
  0.5.34 adds no permissions beyond the checked 0.5.33 review package.
  Tests use isolated offline environments and synthetic fixtures; no live
  payment or physical-device test is claimed.
- This handoff records the source commit and release notes only. The ZIP
  remains a review package: no GitHub release, public website/update-channel
  change or Chrome Web Store publication/approval is implied.

Review ZIP: `kaspire-extension-0.5.34-review.zip`

SHA-256: `e083a5c7c0d0ebb022f3df1a4b011bd8bed42a6609a7adfbe5320c4f74060413`
