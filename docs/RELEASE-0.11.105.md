# Kaspire Android 0.11.105

2026-11-13. Complete cumulative changes since public Android **0.11.104 (249)**.
Includes the changes validated in test APKs 0.11.105-test.1 (250) and
0.11.105-test.2 (251). Public Android build: **252**.

## Kaspa News — mobile connection enabled

- Corrects the browser catalog's read-only configuration for Kaspa News.
  Its Kaspire Mobile connection, including the subscription flow reached
  after email login, can now open WalletConnect pairing and wallet approvals
  inside Kaspire's dApp browser.
- Existing origin checks, explicit connection approval, transaction review
  and signing controls remain in place. No login or payment is performed
  automatically by this change.

## Kaspa Vision and KasPass

- Adds **Kaspa Vision** immediately below Kaspa News in the dApp browser,
  using its official bundled logo. The homepage and `/signin` login route
  remain accessible inside the browser.
- Allows Vision's membership checkout to navigate to the exact HTTPS origin
  **pass.kaspa.vision** and return to Vision. This is not a wildcard subdomain
  allowance or a general external-browser navigation exception.
- KasPass pairing is bound to the actual checkout page's origin. A KasPass
  proposal cannot substitute Vision's identity or another website's identity;
  phishing checks and ordinary approval/signing controls remain unchanged.
- The connection onboarding hint stays hidden for the current browser visit
  after a matching session has been observed, even when the website ends its
  WalletConnect session after signing in. This UI state does not authorize
  requests, persist a wallet connection or bypass a new approval.

## Delivery and checks

- Retains the official Android package and signing identity, with both
  `arm64-v8a` and `armeabi-v7a`. Native signing cores and Android permissions
  are unchanged from public 0.11.104.
- **Both update options remain available:** the classic official-website APK
  download and the matching GitHub Release APK through Kaspire's signed
  in-app updater. Both deliver the same APK and checksum.
- Regression checks cover catalog order and official logo, narrow layouts
  across all themes, exact permitted/blocked origins, short-lived session
  onboarding, KasPass peer identity, scam rejection and pending-request
  recovery. The public build repeats the 38 focused Flutter tests and static
  analysis, followed by APK, signing, configuration and download checks.
- The user confirmed the test.2 Vision/KasPass flow works. No live user
  payment or authenticated email login was performed by the build process.
- Browser Extension **0.5.29** and the experimental iOS PWA are not changed
  by this Android release. Unrelated in-progress marketplace/server work
  is excluded from the release package and commit.
- Release notes remain on GitHub only; website download cards show release
  version, downloads and checksum, without inline release notes.

Verified Android APK SHA-256:
`36cff6f5f50f278273d90640aee245917c8bf40c0eeaccfc2d24c4bf81d8b546`
