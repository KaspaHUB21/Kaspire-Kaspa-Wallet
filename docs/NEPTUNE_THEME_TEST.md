# Neptune — Android private test

## Revision 2 — globe alignment

Test version **0.11.47-neptune.2 / 138**. The Kaspire logo is anchored to the
actual globe center (55% horizontally, 40% vertically within the asymmetric
ornament), rather than the full raster center. It no longer overlaps the
crescent or lower trident. All other Neptune visuals remain unchanged.
Flutter analysis is clean; 13 Neptune tests pass, including a new logo-anchor
regression test and the visually inspected updated preview. The existing
Android package ID and signing lineage are retained. A future public release
must use a versionCode above 138.

Artifact: `artifacts/neptune-test/Kaspire-Android-Neptune-v0.11.47-test2-build138.apk`.
SHA-256: `77013d2fd56a1d8426a29129e39ac219588f833b6cb9f89d8959065cdcd2ba9b`.
Signatures verified for API 30–32 and API 33+; APK alignment verified.
Unlisted test download:
`https://kaspire.kaslab.space/downloads/tests/neptune-build138/Kaspire-Android-Neptune-v0.11.47-test2-build138.apk`.

## Initial revision

Enable under Settings → Wallet display → Kaspire design → Neptune.
Midnight remains the default and existing stored theme names are unchanged.

Version override: **0.11.47-neptune.1 / 137**, package `space.kaspire.wallet`,
Android 11+, ARMv7 and ARM64. The public version in pubspec, website metadata,
signed update manifest, WalletConnect fallback and extension remain unchanged.
No GitHub publication is part of this test.

## Rendering

User reference: `neptune.jpg`. The theme follows its turquoise/water-blue
palette, dark water-glass panels, fine warm gold edges, teal-haired marine
character, moon/trident, glass globe, pearls, water ribbons and white lily.
The original Kaspire mark appears inside the balance globe. Handwritten
decorative slogans use the locally bundled OFL-licensed Allura typeface.
Gold crescent/trident footer ornaments are painted natively, not dependent
on device glyph availability. All balances, names, icons and controls remain
real Flutter widgets; generated art contains no financial information.

The shared decorative components cover balances, actions, navigation, cards,
dialogs, settings and send/receive surfaces on Layer 1 and existing L2 screens.
Dark reading panels protect instructions. QR modules keep dark ink against
a dedicated light QR canvas. Artwork is local, excluded from screen-reader
semantics, never interactive, and requires no new network permission.

No signing, seed generation, transaction handling or networking code changed.

## Checks

- Full Flutter analysis: no issues.
- Full Flutter suite: 163 tests passed; all 12 Neptune preview tests pass.
- Neptune layouts at 360×800, 412×900, 800×1280 and 900×412,
  at text scales 1.0 and 1.8; privacy control and persisted preference.
- Receive QR contrast and scrollable copy action.
- Production-widget visual fixture inspected in `test/goldens/neptune-phone.png`.
- No physical device testing performed; user testing remains necessary.

Build uses `flutter build apk --release --target-platform android-arm,android-arm64
--no-pub --build-name=0.11.47-neptune.1 --build-number=137` and the existing
Android signing lineage. A later public build must use a versionCode above 137.

Artifact: `artifacts/neptune-test/Kaspire-Android-Neptune-v0.11.47-test1-build137.apk`.
SHA-256: `d57a401281e0ce36fc8bf8236aaa17e7db4d5b3a5d33bb3e34752502f07201c2`.
APK alignment and v3/v3.1 signatures verified for API 30–32 and API 33+;
certificate fingerprints match the existing website-distributed APK lineage.

Unlisted test download (not an authenticated/private URL):
`https://kaspire.kaslab.space/downloads/tests/neptune-build137-d57a401281e0/Kaspire-Android-Neptune-v0.11.47-test1-build137.apk`.
An exact nginx route serves this test file; the catch-all historical APK
redirect and the official latest APK/update channel remain unchanged.

## Artwork provenance and prompt summaries

Built-in image generation/editing tool, using the user's reference (not CLI).
Final copies live under `apps/mobile_flutter/assets/themes/neptune/`:

- `ocean.png`: remove mockup UI; preserve sea queen, turquoise hair, moon,
  cyan trident and deep ocean; clear center with water/pearl edges.
- `orb.png`: transparent extraction of turquoise glass orb, gold ring,
  pearls, water ribbons and small gold trident; empty center for real logo.
- `assets-ornament.png`: transparent right-side trident, pearl/water ribbons,
  white lily and “Sail the Next Wave” ornament; clear left for real labels.
- `water-glass.png`: low-contrast realistic dark turquoise aquatic crystal
  material, soft caustics, no borders/text/UI.

Font license: `Allura-OFL.txt`, alongside `Allura-Regular.ttf`.
