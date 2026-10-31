# Kaspire Android 0.11.83 — KRON swap recovery and Braid branding

Build **228**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.82/build 227**. The browser extension remains **0.5.27**;
Windows and iOS channels are unchanged by this Android release.

## KRON saved swaps

- Recognize an already accepted saved swap through the own-node transaction
  lookup before broadcasting again. Show its success screen, retain its asset
  activity entry and remove the active recovery block without a duplicate trade.
- After an unsuccessful broadcast, recheck acceptance and independently look
  for a different accepted transaction spending an exact input of the saved swap.
  A verified conflict archives the original signed bytes in encrypted storage,
  clears the active recovery slot and allows a fresh quote.
- Never discard a signed transaction because it is absent from an indexer or
  because an input appears missing. Delayed parents, incomplete history, lookup
  limits, rate limits and unavailable nodes leave the saved transaction intact.
  A retry sends the identical stored bytes, not a newly signed purchase.
- Recheck the original transaction after conflict discovery, before retirement.
  Preserve the active journal if writing its encrypted archive fails. Prevent
  concurrent recovery actions and overwriting a pending swap with another one.
- Check existing recovery on opening a KRON token, independently of balance
  loading. Add **Check status / refresh quote**, display the saved transaction
  ID and replace raw broadcast failures with actionable recovery messages.
- Preserve old recovery-journal compatibility. A new signing attempt checks the
  saved journal again before constructing a trade. Existing pending swaps can
  be checked after installing this update over the current app.

## Braid logo

- Replace the generic route icon in the Swap selector with Braid's official
  three-ring mark, as used by the official Braid app. Bundle the existing
  verified SVG locally rather than depending on a live logo request.
- Preserve the current DEX order, themes, trading fees and swap verification.

## Verification and updates

- **152 Rust tests** and **954 Flutter tests** passed in the complete offline
  regression run; fourteen opt-in or fixture-dependent Flutter checks were
  skipped. The focused 61-test recovery/UI/input-verification/conflict/sell
  regression run and the separate live read-only KRON check also passed.
- Focused recovery, UI, logo, existing input-verification, conflict-pagination
  and sell-preset tests passed. They cover lost broadcast responses, exact-byte
  retries, confirmed conflicts, wrong/unaccepted conflicts, unknown state,
  storage failure and concurrent actions.
- Recovery UI was checked at 320-pixel phone width in Midnight, HUB21, Glacier
  and Neptune. The official Braid logo was checked in all ten themes.
- An additional read-only integration check verified an exact conflicting
  outpoint against real accepted KRON history on Kaspire's node. It used a
  synthetic in-memory recovery journal and seven GETs; it did not import a
  wallet, sign a transaction, broadcast or write to an external service.
- APK version, publishable client configuration, 16 KB alignment, signing
  identity and hosted checksums are verified before publication. Native
  signing libraries and cryptographic checks are unchanged.
- Both update choices use the same signed APK: the official website download
  and the matching GitHub release downloaded inside Kaspire. The signed update
  manifest is published only after the GitHub asset is publicly downloadable.
  Android installation approval is still required. Install over the existing
  app; **do not uninstall or clear app data**.
- Website changes are download version/checksum metadata only. Release notes
  remain GitHub-only.
- Release certificate SHA-256:
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.83.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.83/Kaspire-Android-mainnet-v0.11.83.apk)
- [APK SHA-256](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.83.apk.sha256)
- APK SHA-256: `142d987fc40300ed957dd4fbff5fed69940045aa8d7e29edf81a32fe10cdec77`.
- [All changes since 0.11.82](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.82...v0.11.83)
