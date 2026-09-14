# HUB21 Android theme — private test build

Historical test record: the approved changes are released in Android
**0.11.30 / Build 98**. The private test artifacts below remain documented
for traceability; current download metadata is maintained in `website/app/release.ts`.

Enable under **Settings → Wallet display → Kaspire design → HUB21**.
Midnight remains the default; existing theme preference identifiers are unchanged.

This is an Android-only change. Revision 2 also improves asset sorting and KNS
holdings pagination. No signing, seed generation, network configuration,
transaction validation or extension code is changed. No website, update manifest,
WalletConnect fallback or GitHub publication is part of this test build.

## Rendering

- Gold and silver relief backdrop, generated from the user-provided reference.
- Device-resolution brushed-metal faces and layered machined bevels.
- Neutral metal microtexture overlaid using soft-light blending.
- Real Flutter balance, wallet name, privacy control, actions and asset sections.
- Matching Layer 1 / Kasplex / Igra dashboard controls, navigation, settings,
  send/receive panels, wallet management, token details, cards and buttons.
- The background is decorative, excluded from accessibility semantics, cached
  locally, and requires no network requests. No amounts or UI text are rasterized.
- Existing native Android security dialogs are unchanged.

## Build and checks

Test version: **0.11.30-hub21.1**, Android versionCode **96**.
Version overrides are supplied to Flutter; the public release metadata remains
at 0.11.29 / 95. A future public build should use a versionCode above 96.
The test APK uses the existing Android signing lineage.

## Revision 2 — readability and holdings

Private test version: **0.11.30-hub21.2**, Android versionCode **97**.
Future public builds must use a versionCode above 97.

- HUB21-only dark reading panels protect headings, explanations, available
  balances, token detail headers and version/security footers from the relief
  background. Other themes retain their existing presentation.
- The original Kaspire wordmark has a reactive gold/silver shader and shadow.
- KCC20, KRC721 and KNS are sorted alphabetically, including progressive and
  merged fallback results. KRC20 alphabetical ordering is preserved.
- KNS pagination accepts nested/root pagination metadata and no longer treats
  a short page alone as completion. Successfully loaded pages survive later
  failures; incomplete results are explicitly marked. Requests remain bounded.
- Asset IDs are preferred when deduplicating KNS, so distinct holdings are not
  collapsed solely because their display names match.

Validation: Flutter analysis clean; 102 automated tests pass, including partial
page failures, pagination variants, sorting and HUB21 layouts. Screenshot
fixtures were visually inspected. The reported holder's missing names were not
verified live against an indexer, and no physical Android device was connected.

Build command uses `--build-name=0.11.30-hub21.2 --build-number=97`.
Artifact: `artifacts/hub21-test/Kaspire-Android-HUB21-v0.11.30-test2-build97.apk`.

SHA-256: `723428e86aa96e19ea4781c5e3933efd40315bbc1a9fd18af9d009cc3900d240`.
APK v3/v3.1 signatures and the existing signing lineage verified; package
`space.kaspire.wallet`, minSdk 30 (Android 11), targetSdk 36, versionCode 97.

## Initial revision artifact

Artifact: `artifacts/hub21-test/Kaspire-Android-HUB21-v0.11.30-test-build96.apk`

SHA-256: `c5ae29ef693b7acf72c0895a7ecb49c7e1a8607b400c9172f3287b4e34c3421a`

Verified v3/v3.1 signatures, Android minSdk 30, targetSdk 36, both ARM ABIs,
and inclusion of the native core and both theme texture files.

```sh
cd apps/mobile_flutter
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub --dart-define=HUB21_GOLDENS=true --update-goldens test/hub21_theme_test.dart
flutter build apk --release --target-platform android-arm,android-arm64 --no-pub --build-name=0.11.30-hub21.1 --build-number=96
```

The optional golden test uses `FLUTTER_ROOT` to load the SDK's Roboto font.
It renders the production theme components with deterministic fixture data,
not a real wallet or a live balance. The result is
`apps/mobile_flutter/test/goldens/hub21-phone.png`.
Layout tests cover 360×800, 412×900, 800×1280 and 900×412 at text scales 1.0/1.8,
theme preference persistence, privacy toggling and action taps.
These are automated Flutter checks, not a claim of physical-device verification.

## Asset provenance

Generated with the built-in image generation/editing tool (not the CLI/API
fallback). Both selected images are copied into the project:

- `apps/mobile_flutter/assets/themes/hub21/relief.png`
- `apps/mobile_flutter/assets/themes/hub21/brushed-metal.png`

Reference: user attachment `kaspirehub21.jpg`. It is used as a visual reference,
not shipped as an app screen.

### Final backdrop prompt

Create a production raster BACKGROUND ASSET only for a Flutter wallet theme,
portrait 1024x1536. Reference image is STYLE REFERENCE. Reconstruct ONLY the
luxurious repeating angular interlocking labyrinth of thick extruded gold and
dark silver metal visible BEHIND the UI in the reference. Fill entire canvas
with that same sweeping curved geometric maze relief, black recesses, machined
bevels, amber rim lighting, silver graphite in central top region and rich gold
toward edges. Precisely match the reference metallic aesthetic and contrast.
Remove ALL user interface, all panels, cards, buttons, icons, letters, numbers,
logo, status bars. Absolutely NO text, NO UI, NO coins. This is the background
texture layer for real separately rendered UI. Fine brushed realistic metal,
high quality sculpted 3D material, not flat illustration. Save generated asset.

### Final metal prompt

Use case: stylized-concept. Asset type: production PBR-style brushed metal
texture for a luxury gold-and-silver wallet user interface. Create a square
1024x1024 seamless neutral grayscale texture of extremely fine horizontally
brushed satin metal, microscopic realistic machining scratches and gentle
mottling, mostly middle gray. Orthographic flat macro material swatch. Texture
only, completely fills frame. No borders, no objects, no lettering, no logo,
no interface, no perspective, no strong lighting or color gradient. This is a
subtle neutral microtexture intended to be soft-light composited onto separately
drawn silver and gold beveled UI panels. Fine photographic material detail,
not distinct big stripes.
