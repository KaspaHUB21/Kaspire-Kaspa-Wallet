# Kaspire Browser Extension 0.5.14 — P2SH reliability

- Match P2SH Receive, Send and Activity controls to the active wallet theme and
  ordinary wallet layout, including HUB21, Glacier and Neptune.
- Preserve popup dimensions when navigating between ordinary Receive and P2SH.
- Use Kaspire own-node history without competing against public-provider
  cooldowns, and retain valid empty local history when a public provider fails.
- Harden the shared WASM secret boundary with owned mutable UTF-8 buffers,
  clear temporary JS buffers, and wipe mutable derived backup keys after import.
- Preserve encrypted backup compatibility, derivation paths, address retirement
  and existing unlock/expiry behavior.

The existing ZIP was submitted to Chrome Web Store review by the maintainer.
It was not rebuilt for the Android 0.11.54 release. Store approval and rollout
are separate from availability of this downloadable package.

150 extension tests passed; TypeScript reports no errors. Previous focused
Chromium UI/session verification is documented in
`docs/p2sh-hardening-build189.md` and the P2SH implementation notes.

This is memory hardening, not a claim of guaranteed erasure of JavaScript
strings or all browser-memory copies. P2SH hides public keys until spending;
it does not make Schnorr signatures post-quantum.

ZIP SHA-256: `a6882357e67548e38818ab07bd972f00d123b85006b42d0931f7a777ba8b02d0`.
