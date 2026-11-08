# Kaspire Android 0.11.99 — KDOLLAR swap fee fix

Public Android release, build 244. Complete changes since Android 0.11.98.
Android 11 or later; ARM64 and ARMv7.

- Fixes KDOLLAR KaspaRocket swaps rejected with “Mainnet fee payout differs
  from reviewed terms”. KDOLLAR's deployed pool uses the KaspaDollar donation
  recipient for its treasury leg, rather than KaspaRocket's ordinary treasury.
- Adds a fixed recipient mapping restricted to KDOLLAR covenant
  `e5554a63a0fddf927fce200d55d7019e102d664c6d735063a7277936dc680a2c`
  and pool `2727d248acf34e81517afa28f58d5de023312e48ecdc5af8a1a7136ecbc4e0ce`.
  Other pools retain the existing treasury pin. API-provided recipients are
  not accepted dynamically.
- Fee amounts and Kaspire's partner payout remain checked exactly. Review
  binding, every selected input's SIGHASH_ALL, full funding, own-node checks
  and local contract execution remain required.
- Includes an actual unsigned KDOLLAR Mainnet buy plan as regression data.
  Tests replace wallet funding with synthetic keys, sign locally and execute
  the covenant scripts. Additional tests reject redirected and changed fee
  outputs directly, independently of stale-sighash rejection.

No real-wallet signature, trade submission or payment was performed during
verification. Mainnet buy and sell share this fee validation; no funded live
sell is claimed. The actual release APK is checked for both updated native
libraries and the unchanged Android signing identity.

Both update routes remain available: the official website APK download and
the matching GitHub-release download inside Kaspire, with the existing signed
update manifest. Install over the existing app; do not uninstall or clear data.
Android still requires installation approval.

All changes from 0.11.98, including Kasvio-first discovery and removal of the
obsolete Top-100/legacy notices, are retained. Website download metadata is
updated; release notes stay on GitHub. Extension, iOS PWA and Windows releases
and update channels are unchanged.

Validation: 167 Rust core tests and 1,150 full-suite Flutter tests passed
(17 explicit optional skips). A final focused run passed all 12 PSKT tests,
including direct fee-recipient/amount mutations and synthetic local-VM signing
of both the ordinary treasury fixture and KDOLLAR's actual unsigned plan.

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.99.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.99/Kaspire-Android-mainnet-v0.11.99.apk)
- [Checksum](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.99.apk.sha256)
- [Changes since 0.11.98](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.98...v0.11.99)

APK SHA-256:
`d79078f59b421caa80267cf3e48cda5c99ad3601d7b930afdf1fc05326a44041`.
