# Kaspire Android 0.11.109 — Responsive lockscreen

2026-11-14. Android build **257**, cumulative changes since public Android
**0.11.108 (256)**.

## Fold-cover and small-screen layout fix

- The lockscreen now measures its actual text and controls before allocating
  space to the mountain and lower landscape. Decorative image heights no longer
  force the user to scroll to reach the unlock actions on narrow phones.
- Artwork scales proportionally into the remaining safe viewport, without
  stretching the logo or moving button hit targets. On taller screens the lower
  landscape stays at the bottom.
- Compact viewports use smaller decorative spacing and heading typography.
  **Use Biometrics**, **Enter wallet PIN** and **Unlock** retain full-size touch
  targets. Screen insets, available updates, authentication errors and text-size
  preferences are included in layout measurement.
- Scrolling is retained when the controls themselves genuinely exceed the
  available height, such as extreme accessibility text sizes. Text is not clipped
  or globally scaled down to force a fit.
- The artwork, theme-independent appearance, native PIN dialog, biometric
  checks, session gating, signing policy and existing transaction flows are
  unchanged. Windows, extension 0.5.31 and the iOS PWA are unchanged.

## Validation and delivery

- 79 automated tests pass, including seven virtual display sizes from 280×500
  to 740×980 with system insets, button visibility/hit testing without scrolling,
  minimum touch sizes, enlarged text, live errors, authentication/session checks,
  all ten themes and both existing update routes.
- The narrow cover-screen layout was rendered with the real artwork and fonts.
  These are local layout tests, not a physical Galaxy Fold test. No live payment
  was performed.
- The release APK retains the exact native libraries, permissions, package,
  release certificate and signing lineage of 0.11.108 on both ARM architectures.
- **Both update routes** publish the identical signed APK: the official website
  download and GitHub Release used by the signed in-app updater. Website version,
  checksum and the signed Android update manifest are updated together.

APK: `Kaspire-Android-mainnet-v0.11.109.apk`.

SHA-256: `815c4e3788a0573fcf640b347ba78c4f502f7050082b9f813200c9159fbbdb3b`
