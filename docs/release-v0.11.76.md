# Kaspire Android 0.11.76 Braid Mainnet and swap route display

Build **221**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.73/build 218**, including the intervening private test builds.
Extension **0.5.27**, Windows, iOS and their update channels are unchanged.

## Braid route display

- Show venue names such as **KaspaRocket** and **KRON**, rather than confusing
  internal identifiers such as `kr`.
- Build the route from Braid's actual `tick` and `side` fields: for example,
  **KaspaRocket: KAS → THEN** or **KRON: PEPE → KAS**. Each leg of a supported
  token-to-token route keeps its own venue and direction.
- Apply the correction to both current quotes and saved swap details. Preserve
  older receipts containing explicit `from`/`to` fields. Missing metadata shows
  a readable fallback, never `null → null`. Long labels fit within the layout.

## Braid Mainnet and partner fees

- Add Braid to Android's Mainnet Swap selection alongside KaspaRocket,
  Kasseal and KRON. Pin the Mainnet r2c router, executor, fee key and supported
  token programs separately from TN10.
- Support the pinned Mainnet tokens THEN, GUZA, KRON, PEPE, IFWEN, ANSEM and
  KASCOV. Use verified token units in amount entry, percentage buttons,
  balances, quotes and saved details: three decimals for these KaspaRocket
  tokens and zero for these KRON tokens.
- Request and disclose a **1% Kaspire partner fee**. The approved recipient is
  `kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq`.
  KAS-input fees are included in the total KAS payment. Token-to-KAS fees use
  the trade's KAS output, excluding returned cell/router reserves.
- For supported atomic token-to-token routes, independently reconstruct the
  input pool's accepted state, verify its pinned covenant, code and P2SH hash,
  and calculate its KAS value using the contract's integer arithmetic. Supply
  that slippage-adjusted value as `tkFloorMax`. Recheck the pool outpoint before
  signing. The input-token fee **plus its KAS cell reserve** stays within 1%.
  Fees below the executable minimum are waived and explained in the review.
  Braid's own fee and network fees remain separate.
- Validate the fee recipient, rate, amount, carrier and valuation again in the
  Rust signing core. Both rebuilt Android ABIs include the Mainnet deposit and
  reclaim profiles and execute signed inputs locally before returning them.
- Keep encrypted Mainnet and TN10 recovery journals separate. Unknown status
  never clears a signed deposit. Verify settlement/refund against the exact
  saved deposit and guaranteed return through independent node data. Preserve
  same-byte retries, receipt export and local recovery after the deadline.
- Remove KaspaRocket, Kasseal and KRON from the TN10 Swap selection. Preserve
  existing assets and recovery data; Braid and KasForge remain available on TN10.

**Limits:** staged KRON-to-KRON routes remain disabled because they have a
different refund flow. The fee-receiving wallet itself cannot trade with its
own fee address under Braid's API rules; use a different trading wallet.
Braid Mainnet is Android-only in this release, not an extension feature.

## KasForge TN10 fixes carried forward

- Adapt the separate Forge API signature envelope to its expected single
  SIGHASH_ALL owner signature. Retain the complete locally verified covenant
  witness and signed transaction for recovery; do not replace it with the API
  envelope or re-sign an existing payment.
- Recover expired or partially prepared saved orders through their verified
  contract path or an explicitly approved return of the exact wallet-owned KAS
  funding. Handle preparation dependencies and confirmed conflicting spends
  without treating a missing lookup as permission for another payment.
  Recovery discloses its 0.1 KAS fee and any required preparation fees.
- Check signed orders automatically while the screen is in the foreground,
  with backoff. Distinguish pending independent confirmation from a rejected
  order and stop polling after verified completion.
- Keep completed filled/cancelled orders in activity rather than the saved
  attention list. Merge retained local history with server activity, show token
  quantities and KAS values where verified, label reserves separately, and
  provide copyable transaction IDs. Forge remains **Testnet 10 only**.

## Updates and verification

The official-site APK download and GitHub in-app update use the same signed
APK, checksum and signed Android manifest. Android still requires installation
approval. Release notes remain GitHub-only, not inline in website downloads.
Install over the existing app; do not uninstall or clear app data. Keep a
current encrypted backup.

- Full regression: **848 Flutter tests passed**, with four opt-in or
  fixture-dependent checks skipped; **147 Rust library tests passed**.
- Route-display tests cover buys, sells, multiple venues, legacy receipts and
  missing metadata. Quote/history layouts and Mainnet token decimals are tested
  in narrow layouts across the wallet themes.
- A captured unsigned Mainnet API build passes the production Dart adapter and
  actual Rust review boundary. The verified reference kit's pool-price result
  agrees with the independent Dart/Rust fixture. These automated checks are not
  a funded Android-device settlement or recovery test.
- Final package checks cover version **0.11.76/build 221**, both Android ABIs,
  the corrected route renderer, the rebuilt Mainnet signing core, configured
  WalletConnect/Rocket clients, 16 KB alignment and the existing v3 identity.
  Signing certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.76.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.76/Kaspire-Android-mainnet-v0.11.76.apk)
- APK SHA-256: `3163012b39aa20afbd8eb81e2eabd41e88e7192ae2e522a3f5ce413a3819d9e5`.
