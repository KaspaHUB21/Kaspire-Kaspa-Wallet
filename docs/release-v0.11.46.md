# Kaspire Android 0.11.46 and Extension 0.5.5

This release improves encrypted backup recovery, receive-address management,
covenant interoperability and KRC20 availability across Kaspire Android and the
browser extension.

## Encrypted backups

- Save Android Argon2id backups directly into the dedicated
  `Downloads/Kaspire-Backup` directory and confirm success in a themed in-app
  dialog.
- Restore a backup during first-run onboarding as well as from Settings.
- Discover backup files through Android's document provider, allow explicit
  file selection or pasted backup JSON, and keep restore controls reachable on
  small screens.
- Require fresh device authentication before a restored wallet is written to
  Android Keystore.
- Introduce stronger backup-v3 exports in the extension while retaining import
  compatibility with Kaspire backup v1 and v2.

## Receive addresses

- Improve rotated receive-address management in Android and the extension.
- Display custom address names, full addresses and consistent right-aligned
  `Used`, `Unused` or `Not checked` status labels.
- Resolve actual address activity without presenting an unavailable indexer as
  a broken wallet.

## KRC20 availability

- Use Kasplex as the sole primary KRC20 source while it is healthy.
- Contact the credential-free Kaspire fallback gateway only after the Kasplex
  request fails, times out or returns an unusable response.
- Keep fallback credentials outside both distributed clients and preserve
  deterministic alphabetical token ordering.

## Covenant and signing compatibility

- Allow reviewed PSKT signing for previously unknown covenant scripts when the
  requested input, script and sighash can be verified locally.
- Preserve strict typed validation for known KCC20, KRON and Kaspire covenant
  flows; malformed or unsignable requests still fail with a concrete reason.
- Preserve unknown safe PSKT fields and explicit input signing metadata needed
  by external marketplaces and covenant applications.
- Shorten the Android managed-memory lifetime of decrypted wallet material and
  keep signing work scoped to the native call boundary.

## Security and compatibility

- Android package `space.kaspire.wallet`, version 0.11.46, build 136.
- Browser extension version 0.5.5.
- Preserve Android 11+ support and the established Android signing lineage so
  existing installations can update normally.
- Keep the signed Android update manifest and every Android download route on
  the pinned Kaspire host.
