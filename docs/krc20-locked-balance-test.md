# Android KRC20 PSKT-locked balance test

2026-11-12. Separate test APK **0.11.103 (248)**, based on public Android
0.11.102 (247), commit `17d06cf`. No Android update manifest, public website
release/version, GitHub release, extension or iOS channel changes.

## Behavior

- The existing Kasplex address `tokenlist` response already includes `locked`,
  in the same raw token units as `balance`. The authenticated KRC20 mirror
  follows the same parser. No order-listing or per-order KaspaCom calls are
  added, and no marketplace attribution is inferred from the indexer.
- `balance` / `rawBalance` remain strictly spendable. The new optional
  `rawLockedBalance` is display-only and uses exact integer/decimal formatting.
  Wallet rows, token details and the asset-send screen display a separate
  `+2,000 SOULS locked` line when the reported amount is positive.
- Fully listed tokens remain visible even when their spendable balance is zero.
  Missing/malformed locked values are not invented as zero, and a missing
  available balance is not converted to a zero-balance holding.
- Paging deduplicates symbols instead of summing repeated rows. Refresh replaces
  current locked quantities; market enrichment and progressive snapshots retain
  them. Privacy mode masks quantities. Other asset protocols remain unchanged.
- Sending and Max continue to use only the original spendable amount. No
  transaction/signing/recovery rules or native Rust binaries are changed.

## Verification

- A read-only live Kasplex check for goatmilk.kas returned KASBTC
  `balance=9435600672795`, `locked=2100000000`, `dec=8`: 21 locked KASBTC.
  This was only an indexer read; no payment/listing operation was performed.
- 91 focused Flutter tests pass: parser, mirror fallback, cursors/duplicates,
  refresh/unlock, malformed/missing amounts, fully locked holdings, market
  enrichment, progressive snapshots, Max excludes locked tokens, privacy and
  narrow layouts in all ten themes; existing wallet/API/detail/activity tests.
- Targeted analyzer has no errors or warnings; two pre-existing style infos in
  the send/API files remain outside this change.
- APK checks cover both ARM ABIs, package/version/signature, official client
  configuration, 16 KB alignment and byte-identical native signing cores against
  public 0.11.102. The removed legacy KCC20 notices must stay absent.
- Build snapshot takes the released baseline plus only the listed KRC20 changes;
  unrelated uncommitted marketplace/server experiments are not packaged.

This is a test build for device validation, not a claim of an executed live
listing/send test or physical-device end-to-end coverage.

Download: <https://kaspire.kaslab.space/downloads/Kaspire-Android-v0.11.103-KRC20-locked-test.apk>

Checksum: <https://kaspire.kaslab.space/downloads/Kaspire-Android-v0.11.103-KRC20-locked-test.apk.sha256>

APK SHA-256:
`5e2eaaae390ea1ebabae9c6bcdd8374c62405e0693246c106687302205e1e779`.
The direct HTTPS download returned 200 without a redirect, and its complete
downloaded bytes match this hash. Production update manifest, website index and
latest public APK checksums remain unchanged.
