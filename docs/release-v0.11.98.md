# Kaspire Android 0.11.98 — KCC20 discovery notice hotfix

Public Android release, build 243. Complete changes since Android 0.11.97
(build 242). Android 11 or later; ARM64 and ARMv7.

## Correct indexer priority and remove obsolete notices

- Removes the blanket “Kascov exposes the top 100 holders” warning from the
  asset overview. An optional fallback's holder-list limit is not a reason to
  warn about every successfully loaded Kasvio balance.
- Kasvio is the primary standard-KCC20 holdings source. Successful reads no
  longer start competing Kascov or KCC20.info scans. Global indexing gaps that
  Kasvio explicitly says are not attributable to this wallet do not trigger
  those scans either; internal partial-coverage state is still preserved.
- Kascov is consulted after actual Kasvio read/verification problems. The
  retiring KCC20.info reader is only last-resort compatibility if that fallback
  fails or lacks required mapping data, not a normal discovery dependency.
- Removes obsolete fallback-repair and legacy-source-unavailable notices.
  True Kasvio outages remain visible, and positive loaded holdings are retained.

## Avoid false errors for independently handled and obsolete contracts

- Correctly delegates Kasvio's recognized KForge 6-input/6-output family to
  the existing KForge integration, as already done for KaspaRocket's recognized
  family. These tokens no longer generate an additional standard-token
  “could not be verified” warning. No new signing template is enabled.
- Quietly excludes both known identifiers of the unsupported pre-final legacy
  template (Kascov KCC1 and canonical SilverScript) from discovery warnings. Unknown templates, mismatched
  identities, invalid units and failed supported-token reads are not hidden.
- Marks real per-token/pagination failures as incomplete coverage rather than
  treating the result as a complete empty wallet.
- No changes to signing, local node checks, transfer limits, keys, backups or
  saved-swap recovery. Native signing libraries are unchanged from 0.11.97.

## Update and scope

Both update routes remain supported: the official website APK download and
the matching GitHub-release download inside Kaspire. Both deliver the same
signed APK through the existing trusted update manifest. Install over the
existing app; do not uninstall or clear wallet data. Android still requires
installation approval.

The website updates its download metadata and Android source description;
release notes remain on GitHub, not embedded in the download section.
Extension, iOS PWA and Windows versions and update channels are unchanged.
The KasForge Mainnet integration and all twelve browser entries from 0.11.97,
including KasCoven Vaults last, are retained.

## Verification

The full regression run passed 166 Rust core tests and 1,150 Flutter tests
(17 explicitly skipped optional checks). After including both historical
identifiers of the same legacy contract, a final focused run passed 93 tests
(one optional live check skipped). These include captured public Kasvio
responses for the reported wallet, exact KForge-family delegation, mismatched
and unknown-contract rejection, genuine outage/partial-coverage reporting,
progressive updates, and proof that healthy Kasvio reads never request either
legacy indexer. Static analysis reports no errors or warnings, only style info.

The release package is checked for both ARM ABIs, unchanged native signing
libraries, the removal of the obsolete messages, retained real-error messages,
release signing identity and public-client configuration. No transaction was
signed or broadcast during this hotfix validation.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.98.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.98/Kaspire-Android-mainnet-v0.11.98.apk)
- [SHA-256 checksum](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.98.apk.sha256)
- [Changes since 0.11.97](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.97...v0.11.98)

APK SHA-256:
`e3aa118df05c04ea6608d27d229dc13653bbccab04e17add618bf4cc2bba359e`.

Unchanged Android signing-certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
