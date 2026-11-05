# Kaspire Android 0.11.94 — KForge verification hotfix

Public Android release, build 239. Complete changes since public Android
0.11.93 / build 238. Android 11 or later; ARM64 and ARMv7.

## Fix frequent independent KForge lookup failures

- KForge input verification previously launched up to four node requests in
  parallel against a shared reader with three concurrent slots. A four-read
  request reproduced HTTP 503 on our own service. The application treated that
  temporary overload as a permanent failure and displayed a raw Bad state error.
- Input lookups now run one at a time, with 220 ms spacing between different
  addresses. Inputs sharing an address reuse its response within that single
  verification. The cache is discarded afterwards: signing still performs a
  fresh independent check after user approval.
- Read-only HTTP 429, 502, 503 and 504 responses get at most three retries with
  bounded backoff. Retry-After is capped; requests and waits share a deadline.
  A complete input-verification pass retains its 15-second time budget.
  Timed-out in-flight requests do not cause overlapping retry requests.
- If verification remains unavailable, the app displays a readable retry
  message without the Bad state prefix. Unavailable data never becomes a zero
  balance, accepted payment or proof that a saved swap is obsolete.
- The change applies to KForge Mainnet and Testnet 10, including quote review,
  pre-sign verification and saved-transaction checking. No signing/submission
  POST is automatically retried by this read helper. The existing same-byte
  recovery flow, encrypted receipts and conflict-proof requirements are retained.

Independent comparison of scripts, amounts, covenant IDs and inputs is not
bypassed. Native review binding, mass/fee checks and complete local script
execution are unchanged. This hotfix does not raise server connection limits or
loosen signing policy. KasForge and the other swap venues are unchanged.

## Release and verification

163 Rust core tests and 1,131 full-suite Flutter tests passed (18 optional
live/snapshot checks skipped). The additional focused KForge run passed 135
tests, including the strengthened overload/deadline tests, with one optional
snapshot check skipped. Analysis reported no errors or warnings, only style
information. Both packaged native libraries match the previously verified core;
the new lookup message is present and the old error is absent in both ABIs.

The regression tests cover a real captured four-input Mainnet buy through the
production quote adapter and native Rust review, simulated three-slot overload,
temporary/permanent HTTP failures, bounded retry delays and timeout, per-pass
deduplication, fresh rechecks on both networks and retention of saved bytes.
The release also runs the complete Rust/Flutter suite and inspects the actual
ARM64/ARMv7 APK. No funded live swap or physical-device settlement is claimed.

Both update choices—the official website and the in-app GitHub release
download—deliver the same signed APK. Existing Android signing identity,
lineage, compiled public-client configuration and signed-update trust remain
unchanged. Install over the existing app; do not uninstall or clear wallet data.
Android still requires installation approval.

The website updates download metadata only; release notes remain GitHub-only.
Extension 0.5.27, Chrome Web Store status, Windows, iOS PWA and their update
channels remain unchanged. Unrelated KaspaCom experiments are excluded.

Android signing-certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

Official APK: https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.94.apk

GitHub APK: https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.94/Kaspire-Android-mainnet-v0.11.94.apk

Checksum: https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.94.apk.sha256

APK SHA-256:
`ea18f145d014cf9fce2e121e4fa4b207020eccfcb630e905ff3d4e029fdb627f`.

All changes since the last public Android release:
https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.93...v0.11.94
