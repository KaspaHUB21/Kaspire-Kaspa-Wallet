# Kaspire Android 0.11.102 and iOS PWA 0.1.0-ios.24

Android build 247 (Android 11+, ARM64 and ARMv7). Changes since Android
0.11.101 and iOS PWA 0.1.0-ios.23:

- Removed the wallet-wide stale-indexer and unverifiable-holdings notices.
  Valid holdings still appear if an individual row cannot be verified.
- Stale or retained results and unresolved rows still count as incomplete;
  they are not evidence of a zero balance. Actionable outages and incomplete
  pagination still show their existing notices.
- Kasvio V4 remains primary, with Kascov as fallback. The fix does not expand
  supported contracts or change transfer preparation, live-cell checks,
  authorization, signing, or saved transactions.

Android retains both update options: the [official APK download](https://kaspire.kaslab.space/#download)
and the matching GitHub APK through the in-app update. Install over the existing
app. On [kaspire.me](https://kaspire.me/), use the existing PWA update without
clearing site data or reinstalling. The PWA retains the .23 signing worker and
WASM unchanged. The browser extension and Windows channels are unchanged.

Verified: 119 Android and 44 PWA regression tests passed, with optional
external reads skipped. The signed Android APK was checked for the existing
signing identity, both ARM ABIs, unchanged native libraries, and removal of
both notice strings. The packaged PWA was exercised in Chromium with stale,
unresolved and unavailable indexer data, including a read-only fallback and
unsigned plan reconstruction. No funded transaction was signed or submitted.
