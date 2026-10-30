# Kaspire Android 0.11.78 Braid token selection fix

Build **223**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.77/build 222**. Extension **0.5.27**, Windows and iOS are unchanged.

## Braid token balances

- Fix the immediate **POST required** error when selecting a token as the input
  for a Braid swap, including token-to-token swaps. KAS input was unaffected
  because it does not need a token-note lookup.
- Use Braid's documented **GET /merge-notes** read endpoint under the router
  API instead of **/notes**. The old path returned HTTP 405 and a misleading
  request-method error; changing that old path to POST would not fix it.
  This GET request only lists notes; it does not merge or move tokens.
- Verify the response's network, token identity, complete note list and valid
  raw quantities before displaying a balance. Preserve verified token units:
  for example, 29,978 raw THEN units display as **29.978 THEN**.
- A successful empty note list is zero. A failed or malformed lookup remains
  unavailable, never a fabricated zero. Saved swaps and recovery receipts stay
  intact. No signing rules, partner fees, token allowlists or route permissions
  change in this hotfix.

## Verification

- Full Flutter regression: **872 tests passed**; six opt-in or
  fixture-dependent checks were skipped in the offline suite. The two new live
  read-only note tests were run separately and **both passed**.
- Add regression coverage that exercises the real service HTTP method and
  endpoint on Mainnet and TN10, plus token-to-token selection through the actual
  screen/service path without replacing the note loader.
- Cover positive, empty, failed, malformed and wrong-network/token responses.
  Existing quote, signing, recovery, theme and update regressions remain in scope.
- Separate live read-only tests passed on Mainnet with an existing THEN holding
  and on TN10 with an empty holding. Neither signs, submits or broadcasts a
  transaction. A physical-device funded swap was not executed for this hotfix.
- Package checks confirm version 0.11.78/build 223, the corrected endpoint and
  validation code in the compiled app, both ARM ABIs, configured clients,
  16 KB alignment and unchanged native signing-core hashes. The v3 signing
  certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Updates

Both the official-site download and GitHub in-app update use the same signed
APK, checksum and signed Android update manifest. Keep the existing installation
and wallet data; do not uninstall. Android still requires installation approval.
Website download metadata is updated; release notes remain GitHub-only.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.78.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.78/Kaspire-Android-mainnet-v0.11.78.apk)
- APK SHA-256: `6bb3be113a39cadb92c35d028771c60f642df0c53d7ebfa119144f9a059e7d50`.
