# Kaspire Android 0.11.82 — Braid swap reliability

Build **227**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.80/build 225**, including the fixes first distributed separately
in 0.11.81 and 0.11.82. The browser extension remains **0.5.27**; Windows and
iOS update channels are unchanged.

## Braid swap review

- Fix **type List<dynamic> is not a subtype of type Map<dynamic, dynamic>**
  when reviewing a token swap. Current Braid builds can return token-change
  hints as a list. Kaspire now reconstructs the wallet's change from the token
  input scripts and the selected amount instead of relying on that hint's shape.
- Match the reconstructed change to the actual transaction output before review.
  Invalid, missing, duplicated or redirected token change remains rejected;
  native review, fee limits and saved-transaction safeguards remain enforced.
- Preserve secure random deposit nonces. A deterministic nonce is used only by
  the offline test fixture, not by production swaps.

## Missing or stale pool data

- Fix token-to-token quotes failing immediately with **No independently
  verifiable input pool hint**. A missing or malformed quote hint now triggers
  fresh pool discovery rather than an immediate failure.
- Refresh stale hints before walking transaction history, addressing repeated
  **Pool changed; its new state is not indexed yet** failures when the quote
  and the current pool state are out of sync.
- Match discovered hints to the independently pinned token, pool covenant and
  venue. Remote reserve values and remote verification flags are not trusted.
  Only outpoints are cached; every reuse is independently checked again.
- Use a second fixed independent Mainnet transaction/history indexer when the
  first indexer is unavailable or behind. The current pool output must still
  be present in the live UTXO set returned through Kaspire's own node gateway.
  Public history cannot substitute for that own-node check.
- Bound chain lookups and history traversal. Conflicting spends are matched by
  their exact previous outpoint, and ambiguous pool continuations are rejected.
  Missing or unverifiable state remains a visible failure, never a zero balance
  or permission to sign without proof.
- Verify retry behavior: a failed refresh removes the old quote's review action;
  a successful retry restores it without recreating a payment.

## Verification and installation

- Promote the exact signed APK successfully tested by the user. No new runtime
  changes were introduced between that test download and this public release.
- **152 Rust tests** and **917 Flutter tests** passed in the full offline run;
  eleven opt-in/fixture-dependent Flutter checks were skipped. A subsequent
  **37-test** focused run also passed, including the new refresh/retry UI check.
- Eight read-only Mainnet checks passed, including GUZA → THEN with deliberately
  missing/stale hints and a simulated delay in the primary transaction indexer.
  These developer checks did not sign or submit funded swaps; the user separately
  confirmed that the test APK completed their swap.
- APK version, publishable client configuration, 16 KB alignment, signature and
  hosted download checksum were checked. The native Android signing libraries
  are unchanged from 0.11.80; Rust changes in this release are regression tests.
- Both update choices install the same APK: the official website download or
  the matching GitHub release downloaded inside Kaspire. The signed manifest
  advertises this version only after its GitHub asset is public. Android's
  installation approval is still required. Install over the existing app;
  **do not uninstall**. Existing 0.11.82 test installations already contain
  these fixes and do not need a newer build to obtain them.
- Release notes remain GitHub-only; the website shows download metadata only.
- Release certificate SHA-256:
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.82.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.82/Kaspire-Android-mainnet-v0.11.82.apk)
- [APK SHA-256](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.82.apk.sha256)
- APK SHA-256: `544bc9d62f7734304aba7d3e542d1ea3d9460e6e2bded343e648d3dfa1bd4d98`.
- [All changes since 0.11.80](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.80...v0.11.82)
