# HUB21 extension — private test

The maintainer approved this test package and submitted it to Chrome Web Store
review. It is now distributed unchanged with the Android 0.11.30 GitHub release.
The notes below describe its original private test preparation.

Private package: `apps/browser_extension/artifacts/kaspire-extension-0.4.7.1.zip`.
Manifest version: **0.4.7.1**, version name: **0.4.7.1 HUB21 test**.
During private testing, public manifest/package metadata remained 0.4.7.
The subsequent release records 0.4.7.1 in source, matching the submitted ZIP.
Chrome Web Store approval is not implied by that source update.

SHA-256: `5612ed6091698ab7d25f644bfdb8e2a61aff65fc3e462a737dd2a618edd559f9`.

## Test installation

Unzip into a dedicated test folder. In Chrome's extensions manager, enable
Developer mode and load that folder using **Load unpacked**. Do not uninstall
the existing Store installation to test this build. A separately loaded
extension has separate storage; use a test wallet or watch wallet.

Enable **Settings → Wallet display → Kaspire design → HUB21**. Midnight remains
the default. The theme uses the exact relief and brushed-metal textures packaged
by the Android app, with responsive CSS panels, readable opaque text surfaces,
gold/silver branding and metal controls. Text and amounts remain live DOM text.
No new image generation or remote assets are used for this theme.

## Presentation changes

- KRC20, KCC20, KRC721 collections, KNS and L2 tokens are sorted A–Z in their
  categories. Send pickers are sorted without changing their source records.
- Token ticker case is preserved on rows, details, send pickers and reviews.
  KNS spelling is not uppercased. Non-token UI labels retain natural casing.
- Send preselection handles normalized ticker case; KCC20 identity uses the
  covenant ID rather than ticker alone.
- Lock, Settings and address-copy buttons are 38×38 CSS px. Network is 76×38 px,
  with its arrow after the text. Adjacent dashboard controls have 5 px gaps;
  SVG icons are centered. Tooltip show/hide behavior remains intact.
- Signing, seed generation, transaction validation and permissions are unchanged.

## Reproduce checks and package

```sh
cd apps/browser_extension
npm run check
npm test
KASPIRE_TEST_BUILD=hub21 npm run package
node tests/hub21-browser.mjs
```

33 Node/WASM regression tests pass. The Chromium UI check uses deterministic
local fixtures (no live funds or signing) and verifies sorting, case, token
preselection, KNS spelling, button geometry, tooltip lifecycle, theme switching,
receive QR rendering and L2 ordering. Screenshots in `artifacts/hub21-ui/` were
visually reviewed. These checks do not replace user testing with the installed
extension; the fixture test is not an end-to-end live transaction test.

The theme assets are copied from `apps/mobile_flutter/assets/themes/hub21/` by
the build. Their provenance is documented in `docs/HUB21_THEME_TEST.md`.
