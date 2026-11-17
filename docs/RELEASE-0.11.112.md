# Kaspire Android 0.11.112 and Browser Extension 0.5.32

2026-11-17. Android build **260**, cumulative since public Android
**0.11.110 (258)**. Extension changes are cumulative since public **0.5.31**.

## kUSDT discovery and ordinary transfers on both platforms

- Adds Mainnet kUSDT using the pinned covenant ID
  `50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3`
  and the existing, locally pinned standard KCC20 reference actor.
- Pins the token identity and **six decimal places** when optional indexer
  metadata is missing. Conflicting verified units, mismatched identities and
  unsupported programs are rejected instead of silently rescaling amounts.
- Supports receiving, balance/history display, ordinary owner-authorized
  sending, and reviewed multi-transaction consolidation of fragmented cells.
  Existing progressive discovery, paging, source fallbacks and retained partial
  results remain; unavailable state is not reported as a verified zero balance.
- New recipient/change cells use plain owner states, zero extension and a
  **1.5 KAS carrier reserve per new cell**, separate from the token amount and
  network fee. kUSDT recipient borrowing is deliberately disabled for reference
  wallet interoperability. Existing incoming borrowing policies can still be
  spent with the owner's signature and converted to plain states.
- Ordinary transfers remain limited to valid Mainnet Schnorr wallet addresses.
  Other owner schemes, extended token identities, bridge mint/burn/redemption,
  EVM USDT and a native Trestly swap screen are not enabled by this integration.
  Existing immutable payment journals and duplicate-payment protections remain.

## Token-aware dApp signature review on both platforms

- Generic PSKT approvals now show kUSDT input/output amounts, own token change
  and the draft wallet token balance change rather than only the KAS carrier.
- The shared Rust core decodes token states from the known reference scripts
  and matches their P2SH commitments to the actual input/output scripts under
  the pinned covenant ID. dApp-supplied ticker/amount labels are not trusted.
- Token quantities use exact integer strings and six-decimal display, including
  `0.000001`; reserves stay separately labelled in KAS. The token review is
  bound into the existing review hash checked again at signing.
- Unknown states or unproved wallet ownership prevent a complete net-token
  claim. Outputs not fixed by the requested signature remain identified as
  unbound. Existing covenant-business-rule and partial-signature warnings stay.
- Android uses its native approval dialog; the extension uses its existing
  approval popup or matching side panel. Approval, account/network freshness,
  strict request bounds and signature policies are unchanged. Generic PSKT
  requests remain **sign-only**, with no automatic dApp broadcast.
- Script/transaction checks and token interpretation do not constitute an audit
  of Trestly's pool, bridge backing or off-chain operators.

## Extension cumulative L2 correction

- Extension 0.5.32 also includes the shared-core Igra/Kasplex encoding correction
  published in Android 0.11.110 after extension 0.5.31. Leading zero bytes are
  removed from ECDSA signature scalars before RLP encoding, preventing strict
  RPC decoders from rejecting otherwise valid native/EVM-token transfers.
- EIP-155 chain binding, sender verification, review authorization, nonce, gas,
  destination, value and calldata checks remain unchanged. This is not a switch
  to a different transaction type. Android retains its already-published fix.

## Validation and delivery

- **181 Rust tests** passed, including local consensus-VM execution of kUSDT
  transfers and multi-step plans, script/preimage matching, wrong identities,
  unbound/unknown states and review-tampering rejection.
- **102 selected Flutter tests** passed with one existing skip. Native dApp
  reviews, explicit approval/rejection, narrow 320px layouts and themes,
  discovery, exact units, recipient policies and recovery are covered.
- **302 extension/WASM tests** passed with six existing skips, together with
  TypeScript checks and actual packaged Chromium provider/approval tests.
  Coverage includes token-aware PSKT signatures, four-theme 320px reviews,
  delayed discovery/reopening and payment cancellation/recovery through the
  real popup and Chrome side panel.
- The actual extension WASM also passes **2,048 canonical Igra/Kasplex
  signatures**, including the exact leading-zero regression and rejection of
  changed reviews, senders and unsupported chains.
- The APK's ARM64/ARMv7 libraries match the checked native builds after normal
  release stripping. Package identity, other native libraries, permissions,
  release certificate and signing lineage are preserved. Extension identity and
  permissions are unchanged. No live payment or physical-device test is claimed.
- Public APK and ZIP bytes are identical to the checked 0.11.112 / 0.5.32 test
  packages; only their public download filenames change.
- **Both Android update routes** provide the identical signed APK: the website
  download and matching GitHub Release. Website version/checksums, the signed
  Android update manifest and GitHub assets are updated together without
  changing installed clients' update trust. Release notes remain on GitHub,
  not embedded in the website's download section.
- The combined GitHub Latest release covers both platform versions and includes
  their APK/ZIP and checksums. ZIP publication is not Chrome Web Store approval;
  store rollout remains separate.
- iOS-PWA source/builds and unrelated in-progress marketplace changes are
  excluded from this commit and release. Existing wallet data is preserved.

Android APK: `Kaspire-Android-mainnet-v0.11.112.apk`

SHA-256: `66b124f6d09c92351215fe4743a513aeea3a5daaf01988efe1b2dccd6f46b68d`

Extension ZIP: `kaspire-extension-0.5.32.zip`

SHA-256: `bc3e187b33d2a5fef507bfaa5af38eee6e3469fcbd02460743958c23415e3426`
