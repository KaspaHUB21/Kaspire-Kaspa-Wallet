# Kaspire Android 0.11.72 — Forge order submission hotfix

Build **217**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.71/build 216**. Extension **0.5.27**, Windows and iOS packages and
their update channels are unchanged. Forge remains **Testnet 10 only**.

## Forge submission and saved-order recovery

- Remove the automatic direct-node deposit fallback after a Forge `/submit`
  rejection, timeout or malformed response. A confirmed deposit alone does not
  register an order with Forge's sequencer and is not a completed swap.
- Keep the exact signed plan and the original submission error in the encrypted,
  read-back-verified journal. Show the last error again when reopening an order.
  Retrying uses the same build ID and signed transactions, never a replacement
  trade. No automatic broadcast bypasses Forge registration.
- Include the token ID in order-status requests. When Forge reports "no such
  order", check deposit acceptance and its exact unspent order output using
  independent chain sources. Show **Deposit confirmed · swap not registered**
  only when that evidence is present, with clear cancellation/recovery guidance.
- Keep missing, spent, mismatched or unavailable data unresolved: never claim a
  refund, successful swap, zero balance or permission for a second trade from a
  missing index record. Preserve the saved transaction and recovery controls.
- Preserve server-independent owner cancellation and final payout verification.
  The existing cancellation confirmation discloses its **0.1 KAS network fee**.
  No signing policy, contract template or Mainnet DEX behavior is changed.

The original cause of the reported Forge `/submit` failure is not established:
0.11.71 discarded that error. This update removes the incorrect fallback,
improves recovery and retains the actual error for diagnosis; it does not claim
that every possible upstream submission failure has been resolved.

## Website and both Android update routes

- Update the official APK, version, checksum and signed Android update manifest.
- Keep both update choices: official website download and the matching GitHub
  release download inside Kaspire, followed by Android installation approval.
- Preserve the existing APK signing identity/lineage and manifest trust.
  Release notes remain on GitHub, not inline in the website download cards.

## Verification

Focused Forge service/widget regression: **45 tests passed**, covering API
rejections, interrupted/malformed submissions, exact saved retries, independent
output checks, journal reopening and narrow layouts in all four themes.
Targeted static analysis reports no issues.

Full regression suites: **778 Flutter tests passed** (3 opt-in live tests
skipped), **145 Rust library tests passed**. The Rust signing core is unchanged
from 0.11.71.

The signed APK was checked for version **0.11.72/build 217**, new recovery UI
strings in both ABIs, unchanged native signing libraries, required public
WalletConnect/Rocket configuration, 16 KB alignment and its v3 signature.
Signing certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

No user order was resubmitted or cancelled during this work. No funded swap or
physical Android-device end-to-end result is claimed. Existing affected orders
remain saved; do not uninstall the app or create a second order while status is
unknown. Export the recovery receipt and keep a current encrypted wallet backup.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.72.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.72/Kaspire-Android-mainnet-v0.11.72.apk)
- APK SHA-256: `0348fc9c22857d3111a866dc201cf09905b44461ba35ac6dd3ffe9764c0257ee`.

Install over the existing app; do not uninstall.
