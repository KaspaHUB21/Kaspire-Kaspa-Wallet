# Kaspire Extension 0.5.26 — Borrowed Receive and Side Panel approvals

Local package only. No website, Git commit, Chrome Store upload or public update
manifest is changed by this build. Extension name remains Kaspire Wallet.

- Includes the 0.5.24 Activity/logo/layout work and the 0.5.25 in-panel dApp
  approvals. The open panel belonging to the caller's browser window presents
  the original approval; otherwise the ordinary popup remains the fallback.
- Standard KCC20 and KaspaRocket transfers can consume one eligible recipient
  cell as the borrowed leader. Sender inputs remain separately authorized.
  The native core rebuilds the exact transaction, binds the review hash and
  executes all contracts locally. Recipient ownership, extension, full threshold
  guard, existing token balance and KAS deposit are preserved. Only the intended
  token amount is added. No recipient signature is forged or requested.
- Recognize existing owner-authorized standard cells with borrowing policies.
  Newly created standard receiving/change cells enable zero-threshold receipts.
  Automatic reuse supports permissionless amount-threshold policies only:
  disabled cells stay disabled, and signature/hash-chain guards cannot be
  bypassed. Sender consolidation reserves the extra final recipient-input slot.
- Kasseal and legacy KRON production paths remain unchanged at the user's request.
- Fix Activity unit selection: verified Kasvio token units take precedence over
  missing genesis decimals and old indexer fallbacks. Verified receipts cannot
  be overwritten by a later legacy display result. Unknown units are explicitly
  raw rather than silently assumed to have eight decimals.
- Publish standard covenant assets as soon as their own source completes,
  independently of stalled legacy discovery. Scoped UI listeners preserve other
  asset categories and ignore old-wallet/old-view updates.

## Concrete read-only evidence

For BTE covenant `efcf006e57f67e6f0ac90709647bdb5700295a48a3c6b3e7d30b2b724a7b0f1d`,
transaction `7aebbce2de0f5f107050aaba13c25417bbb823413507376e259bb6977ff603c7`
has recipient output amount `250000` raw units. Verified token units are three
decimals, so the transfer is **250 BTE**, not the small legacy Activity amount.

For Kaspire covenant `82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e`,
Kasvio reports receiver owner `3485c974d6e79b75c4ff130ee0cd20ab01b8118329837b2db8ed3b7275777df4`
with `59973229` raw units and verified eight decimals, or **0.59973229 tokens**.
The supplied receiving address's read path is covered by a regression fixture.
The exact cause on the user's installed 0.5.23 instance is not independently
reproduced; the discovered legacy-source loading barrier is fixed and tested.

## Verification

- TypeScript: passed. **263** extension unit/WASM tests: passed, including
  actual WASM borrowing for both pinned 3/3 and 10/10 configurations, rejection
  of invalid receiver state, independent asset publication and exact BTE units.
- **134** native Rust library tests passed. Fixtures use synthetic keys and
  outpoints only; no real transaction was broadcast.
- ZIP integrity, manifest version/name, absence of source maps and server-only
  Rocket credentials checked. Public provider readiness read-only checks passed.
- Actual Chromium Side Panel connect/message/PSKT review/rejection, locked-wallet
  unlock, expiry, close cancellation and popup fallback passed at the 0.5.25
  checkpoint; this presenter code is unchanged. The fresh 0.5.26 Chromium run
  could not start its worker inside the restricted build sandbox, so it does not
  constitute a new successful browser-level check of this exact package.

ZIP SHA-256:
`207ecd64da8c1110ec04318de2aec32e14266db8289b97baaa812d664861cfa5`
