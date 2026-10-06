# Kaspire Android 0.11.48 — WalletConnect hotfix

- Restore the WalletConnect/Reown application identity used by the previously
  working APKs. The 0.11.47 production build accidentally overrode it using
  an outdated release-machine configuration.
- Pin the tested public project ID in source so a stale `REOWN_PROJECT_ID`
  build parameter cannot silently replace it again.
- Add regression coverage, including a test run with the conflicting build
  parameter deliberately supplied.
- Preserve existing wallets, encrypted sessions, Neptune and NFT Market.
- Package `space.kaspire.wallet`, version 0.11.48, build 143. Keep the existing
  Android 11+ signing lineage and pinned-host signed update manifest.

After updating, reopen Kaspire and request a fresh WalletConnect pairing QR
or link from the dApp if the previous pairing attempt expired.

APK SHA-256: `e54ba98f24adf89adab52f998f832bd73c08b79c0cc253b3ee2ac6183a99a312`.
The restored project ID is verified in the compiled APK. Analysis is clean;
186 Flutter tests pass, including 15 WalletConnect configuration/URI tests.
APK signatures retain the previous Android 11–12 and Android 13+ certificates;
16-KiB alignment is verified.
