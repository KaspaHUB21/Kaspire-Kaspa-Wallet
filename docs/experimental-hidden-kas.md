# KIP-22 P2SH KAS account

Released in Android 0.11.53 (188) and extension 0.5.11, under Receive KAS →
P2SH account. Existing ordinary wallet accounts, asset ownership and WalletConnect
accounts are unchanged. This is public-key hiding, not a post-quantum signature
scheme or a general asset account. Native Covenant Vaults remain in Android's
HUB21 Toolbox; dot.k Market is exclusively in K-Agora.

The implementation and recovery format below are pinned to the specified KIP-22
revision. Internal build notes farther down document the development history,
not current feature visibility or publication status.

## Frozen recovery descriptor

`kip22-p2sh-v1`, Mainnet, mnemonic root including any BIP39 passphrase.
Implements account 0 of KIP-22 PR #48, pinned to revision
`b031344f82f4491b9066ef556163509f93833cd6` (2026-10-19, **Draft**, not merged).
Path `m/22'/111111'/0'/branch/index`: receive branch 0, change branch 1.
Purpose, coin type and account are hardened; branch and index are unhardened,
exactly as specified in KIP-22. No account xpub/private-key export or
message/dApp/asset signing route. Imported single private keys are unsupported.
Gap 20, index ceiling 9999 per branch; issuance cannot run past the recovery gap.

Redeem script bytes: `20 <32-byte x-only public key> ac`, i.e.
`PUSH32 public_key OP_CHECKSIG`, exactly as specified in KIP-22.
The 101-byte witness pushes signature+SIGHASH_ALL and the 34-byte redeem script.
Outer P2SH script/address uses Rusty-Kaspa's standard helpers.
The public key/redeem script is derived and validated only inside Rust, including
during unsigned review, and is not returned to Kotlin/Flutter before signing.
The internal `keyHash` metadata is a BLAKE2b-256 commitment, NOT a public key and
NOT the script's constructor argument. Neither it nor an indexer chooses the key.
Freeze these details: changing any of them creates a DIFFERENT account.

This replaces the never-public `kaspire-hidden-kas-v1` experiment, as requested
by its sole tester. No legacy discovery/spending mode or automatic on-chain
migration is provided. Its encrypted local journal is not reinterpreted or
deleted. Backups containing nonempty old P2SH metadata are explicitly rejected
before wallet restoration, with instructions to use the previous build; empty
placeholders from ordinary public-wallet backups are harmless and ignored.

Public test vector — NEVER FUND:
mnemonic `abandon` eleven times followed by `about`, no passphrase, branch 0,
index 0, path `m/22'/111111'/0'/0/0`.
Address `kaspa:pq02dzckvs0g6hhl9s9c484fv0wsd93sltwct9symfad4yw062w5y4v4mtlxa`.
Regression tests independently assemble the minimal script and derive both
branches with the dependency's BIP32 implementation, including gap boundaries.

## Safety properties and limitations

Memory-handling follow-up: see [signing-boundary hardening](p2sh-hardening-build189.md)
for the byte-based WASM verification build, independent node-validator checks,
and the remaining GC-managed JS session/string limitations. Do not interpret
native zeroization as a guarantee that all browser memory is wipeable.

- Hidden account has its own KAS balance/activity screen; ordinary balance is
  unchanged. No automatic migration, no live test spends performed by the build.
- Root plaintext crosses JNI as mutable bytes, never a Kotlin signing String.
  JNI clears the Java buffer; Rust secret/key buffers use Zeroizing. Temporary
  secp keypairs are explicitly erased, subject to normal compiler/copy limits.
- Native code validates seed ownership, descriptor, script, derivation and fresh
  change reservation; reconstructs transaction/review hash, signs SIGHASH_ALL and
  runs all signatures through the local consensus script engine.
- Drain all supplied available native outputs together, max 80. Reject rather
  than silently select a subset, coinbase/covenant inputs, sub-dust change,
  mismatched scripts, duplicate outpoints and excessive mass/fees. Address UTXOs
  are checked again before signing; node acceptance remains authoritative.
- Inputs are durably retired BEFORE signing. Signed bytes are encrypted and
  committed BEFORE returning to Flutter or broadcasting. Failure after signature
  generation never makes the input addresses reusable. Pending bytes block a
  second payment. Only accepted-transaction proof from the fixed HTTPS own-node
  endpoint can clear the pending journal; resume replays the same bytes.
- Previously used addresses are conservatively retired too, even if usage was
  only receiving. Late deposits remain tracked and spendable. Never label missing
  history/network responses as unused, safe, zero, or confirmed.
- Wallet backups include encrypted issued counts, retired coordinates and pending
  bytes. Restoring preserves monotonic counts/retirement and rejects conflicting
  pending payments; imported pending bytes must pass native reconstruction and
  signature verification for the restored seed. AES-GCM metadata AAD binds the
  journal to its wallet ID and descriptor.
- Seed-based discovery reads UTXOs plus address history until the gap is covered.
  Seed alone CANNOT recover off-chain signed-but-never-broadcast exposure or
  abandoned issuance beyond the discovery gap. Keep a current encrypted backup,
  especially after signing; do not run this account on several devices at once.
- Signing exposes the public key. There is still a quantum attack window during
  spending and danger from late deposits to already exposed keys. This is key
  hiding at rest, NOT quantum-resistant Schnorr. No universal CLI/other-wallet
  restoration compatibility or “first wallet” claim is made.

Sources: [KIP-22 PR #48](https://github.com/kaspanet/kips/pull/48),
[pinned KIP-22 draft](https://github.com/kaspanet/kips/blob/b031344f82f4491b9066ef556163509f93833cd6/kip-0022.md),
[Rusty-Kaspa P2SH helpers](https://github.com/kaspanet/rusty-kaspa/blob/v2.1.0/crypto/txscript/src/standard.rs).
Signing dependency remains pinned to Rusty-Kaspa v2.1.0.

## Historical internal validation and device checklist

Automated checks (2026-10-19): all 114 native-core tests passed, including seven
KIP-22 tests; the complete Flutter suite passed 463 tests, followed by all 15
final P2SH tests (including the additional retired-descriptor rejection test).
Targeted Dart analysis reports no issues. Both Android ABIs build successfully.
Signing, recovery and hostile modifications are exercised against the local
consensus VM using synthetic UTXOs; no real funds were broadcast by these tests.

No Android device is connected to the build server. Before wider use, manually
verify with a small amount on the internal build:

1. Create/restore a seed-based HD wallet; open HUB21 Toolbox → KIP-22.
2. Receive KAS to a newly generated `kaspa:p…` address; refresh the separate
   balance. Copying this address must not export an xpub or redeem script.
3. Review and send part of that KAS back to an ordinary address, then spend the
   remaining fresh P2SH change. Confirm amounts and fees on the node.
4. Export an encrypted wallet backup, restore it and verify issued/retired
   addresses and any saved payment are preserved. Resume must submit the exact
   saved transaction, never create another payment.
5. Verify a private-key wallet gets the clear HD-wallet requirement, and an
   ordinary older backup with empty P2SH metadata still imports.

No public update manifest, website, extension package or Git release is changed
for this internal KIP-22 build. It also retains the internal Covenant Vaults
entry through the existing `KASPIRE_INTERNAL_TESTS` flag.

Internal artifact: `apps/mobile_flutter/artifacts/internal/kip22-build183/Kaspire-Android-KIP22-build183.apk`.
Version `0.11.53-kip22.1` / code `183`, package `space.kaspire.wallet`, Android 11+,
ARMv7 + ARM64. Existing release certificate/lineage retained and v3 signatures
verified for API 30–32 and API 33+. Zip alignment is verified for 16-KB pages.
SHA-256: `7f2284f76fee7fce03bf25a95e050bc97b314fb4714499c7cc068de4a06e01ca`.

### Build 184: rate limits and confirmed-payment UX

Superseded for network routing by internal Android build 191 / extension 0.5.14:
P2SH discovery and activity now read the synced own history indexer through
`/api/local-node`, rather than the public-history merge. Own-node and public
read queues/cooldowns are isolated; fresh UTXOs and confirmation never inherit
a public history cooldown. No negative-history or balance cache is introduced.

The gateway's old merge could replace a successful local empty list with a
public HTTP 429. Synced local one-row discovery now short-circuits that fallback,
and valid local empty history is not overwritten by a failed public supplement.
Malformed replies, unsynced history and failed sources still cannot mean zero
balance or unused keys. The own-history route requires a synced database;
confirmation and UTXOs remain pinned to the own node. Retry-After is forwarded.
Nginx isolates bounded own-node reads from the shared market/public API budget
(60 requests/sec, burst 120, no artificial queue delay). Existing global and
market limits are not disabled.

Verification: 516 Flutter tests, 150 extension tests and 14 gateway tests pass;
Dart/TypeScript checks pass. A live, read-only synthetic-address probe completed
three rounds (nine HTTPS GETs) with HTTP 200 for each; no transaction was sent.
This does not claim that an unavailable node/indexer can never return an error.

Original build-184 behavior:

- Discovery, live UTXO rechecks and activity share a request-start queue capped
  at ten GETs/second. HTTP 429 retries are bounded to three attempts with shared
  backoff and support both forms of Retry-After. Long cooldowns fail clearly
  rather than blocking indefinitely. Closing/changing wallet/network stops
  queued reads too. No signing or transaction POST is automatically retried.
- Scan exactly the issued range and twenty unused addresses past the last
  observed/retired coordinate, not whole unnecessary twenty-address blocks.
  Native monotonic retirement metadata avoids repeated history probes for known
  retired keys. UTXOs are always fetched live; no negative-history or balance
  cache is introduced. Failed discovery never means zero balance or unused keys.
- After own-node payment confirmation, show the success panel immediately.
  Discovery only runs on Return to account. A later lookup error cannot turn a
  confirmed payment into a failed one. A submission error retains its original
  cause and displays the native pending journal without another network scan.
- All 471 Flutter tests pass, including 22 P2SH cases. New tests cover parallel
  read pacing, automatic 429 retries, exhausted/long cooldowns, live UTXO reads,
  exact gap coverage, and success/error preservation in the actual widget.

APK: `apps/mobile_flutter/artifacts/internal/kip22-build184/Kaspire-Android-KIP22-build184.apk`,
version `0.11.53-kip22.2` / code `184`. Release certificate/lineage verified for
API 30–32 and API 33+, 16-KB zip alignment verified. Native KIP-22 derivation,
signing and encrypted journals are unchanged from build 183.
SHA-256: `553c459fd2cb5668e43b9ddf2a6fb478a64a326a97c31cddeb1ef7c2be21ef6f`.
Internal only; no public manifest, website, Git push or extension update.

### Build 185: automatic acceptance checks and activity copying

- After submitting the exact saved signed bytes, check native own-node
  acceptance automatically for up to 30 seconds with two-second pauses. An
  initially missing indexer entry no longer immediately demands manual recovery.
  Per-request native connect/read timeouts are five seconds each.
- A recovery operation submits at most one POST, never re-signs, and concurrent
  calls share the same operation. Already-accepted transactions need no POST.
  An ambiguous transport/already-known response still requires native proof.
  Only CONFIRMATION_PENDING is retryable; journal/security errors stop the flow.
- On opening/refreshing a profile with a saved payment, check it automatically
  before starting account discovery. Show progress while waiting; if the bounded
  check expires, keep the journal and offer Check payment status, not a misleading
  Payment incomplete / action required warning.
- Confirmed status still requires the native fixed own-node HTTPS endpoint,
  exact transaction ID, is_accepted=true, and matching wallet/pending journal.
  Closing or changing context stops further Dart polling/submission.
- Activity rows have Copy transaction ID buttons, copying the full original ID
  even when its visible label is truncated, with in-app clipboard feedback.
- All 477 Flutter tests pass, including 28 P2SH tests. Targeted Dart analysis is
  clean. New cases cover delayed/uncertain acceptance, single-flight recovery,
  security failures, closing mid-poll and the actual clipboard button.

Read-only diagnostic: the user-reported transaction was independently returned
as accepted by both the own local REST indexer and
the pinned HTTPS own-node route. No test payment or retransmission was performed
by the build agent. No public release, manifest, website or Git push is made.

APK: `apps/mobile_flutter/artifacts/internal/kip22-build185/Kaspire-Android-KIP22-build185.apk`,
version `0.11.53-kip22.3` / code `185`. Same signing certificate/lineage and
package; verified for API 30–32 and API 33+, 16-KB zip alignment verified.
SHA-256: `cd2cac6c36b583dc8d4d28ae890647b40dddb248b36f1f664778e4f331680416`.

### Build 186: P2SH Max and Kaspa News

- Add Max/Cancel next to the P2SH payment amount. The signing core resolves
  Max from the fresh validated input set, deducts the native consensus-mass
  network fee and creates exactly one recipient output with no change output.
  The exact amount and fee appear in Review before authentication/signing.
- Bind Max mode to the native review hash and saved request. A Max request
  must use canonical amountSompi=0; an explicit hidden amount is rejected.
  Fixed-amount requests keep their existing serialization/review hashes.
  Existing native ownership, retirement, journal and VM checks are unchanged.
- Add Kaspa News (https://kaspa.news/) immediately before KasCoven Vaults,
  using the site's original https://kaspa.news/favicon.png as a bundled image.
  This read-only news entry shows no WalletConnect prompt or wallet deep-link
  handling. HTTPS/exact-host navigation restrictions remain in place.
- Regression tests cover multi-input Max at different fee rates, no change,
  VM signing/recovery, mode/amount tampering, insufficient funds and default
  compatibility. Widget tests exercise Max/Cancel and exact review amounts at
  320px in Midnight, HUB21, Glacier and Neptune without signing.

Internal only: no public manifest, website, Git push or extension update.

Validation: all 483 Flutter tests and 116 Rust tests pass; targeted Dart analysis
is clean. Both Android native ABIs rebuilt and checked against the packaged
libraries. No Android device is attached: real-device Max send and browser
rendering still require a manual check; automated signing uses synthetic UTXOs.

APK: `apps/mobile_flutter/artifacts/internal/kip22-build186/Kaspire-Android-KIP22-build186.apk`,
version `0.11.53-kip22.4` / code `186`, package `space.kaspire.wallet`, Android 11+,
ARM64 + ARMv7. Existing certificate/lineage verified for API 30–32 and API 33+;
16-KB zip alignment verified.
SHA-256: `73e004907d2bddbcd8245c0080c2634e9e4bc2b496d234e2895ce9cac9c2ff79`.

### Build 187 / extension 0.5.10: Receive integration

- Move P2SH from the Android HUB21 Toolbox into a Receive KAS / P2SH account
  segmented switch. Ordinary Receive remains the default. Mainnet only; Windows
  receives no unsupported P2SH entry. Private-key wallets see HD-wallet guidance.
- Use the requested P2SH account title, introduction, recovery/exposure text and
  acknowledgement in both clients; remove the user-facing draft/test wording.
  The derivation, redeem script and pinned KIP revision are unchanged.
- Port the shared P2SH Rust module to WASM with derive/prepare/sign/verify-saved
  and owned-UTXO validation exports. Background-only secret access always uses
  the root mnemonic, never a normal account's signing path. The P2SH account is
  never registered with ordinary addresses, assets, xpub or provider commands.
- Extension commands are restricted to wallet.html, bind the unlock generation,
  account, wallet and network, invalidate reviews on lock and stop on UI-port
  disconnection. Approval is followed by live UTXO and native review rechecks.
- Keep the extension issuance/exposure/pending journal inside each root wallet's
  encrypted vault and its encrypted portable v3 backup. Commit issued addresses
  before UI exposure, retirement before signing, signed bytes before broadcast.
  Resume also re-commits the exact pending journal before POST, so a failed prior
  storage write can never permit a non-durable broadcast. Failed clearing keeps
  the volatile pending record conservatively available.
- Serialize vault writes; guard again before ciphertext persistence and volatile
  session refresh. Keep the ordinary timed-unlock behavior and encrypted offscreen
  session intact. No P2SH secret or redeem-script export is added.
- P2SH requests accept exact canonical decimal strings for amountSompi as well
  as u64 numbers. This enables lossless browser-to-Android recovery; serialization
  and native review hashes stay unchanged. Noncanonical, fractional, negative or
  overflowing amounts fail closed. Verify-saved rebuilds and executes the same VM.
- Extension UI mirrors the Android account, backup, receive QR, new address,
  amount/Max, review, pending/confirmation and TX-ID copy flows. Scope a minimum
  320px / maximum 420px responsive width to P2SH so Neptune cannot crop a narrow
  view or collapse the popup. QR modules remain black on white in all themes.

Validation: all 488 Flutter tests, 117 Rust tests and 126 extension unit tests
pass. Targeted Dart and TypeScript analyses are clean. Chromium UI tests cover
Midnight, HUB21, Glacier and Neptune at 320px, Max, approval rejection, success,
and private-key guidance. The full real-extension Chromium smoke test checks
ordinary wallet/backups, timed unlock, dApp/PSKT context binding and pending reveal
recovery. Its additional P2SH check performs read-only discovery on a randomly
generated unfunded wallet, asserts P2SH metadata is absent from plain local
storage, then preserves the journal through encrypted backup import and actual
service-worker restart. Automated signing uses synthetic UTXOs; no real-fund payment is made.
No Android device is attached; manual on-device P2SH payment validation remains.

APK: `apps/mobile_flutter/artifacts/internal/kip22-build187/Kaspire-Android-KIP22-build187.apk`,
version `0.11.53-kip22.5` / code `187`, package `space.kaspire.wallet`, Android 11+,
ARM64 + ARMv7. Same release certificate/lineage, checked for API 30–32 and API 33+;
16-KB zip alignment verified. Packaged native-library hashes match the new build.
SHA-256: `a0dc051c110397f78de423a2b3d3ee1bad482a650f16a4b15ee7884973a59a55`.

Extension: `apps/browser_extension/artifacts/kaspire-extension-0.5.10.zip`.
Manifest name is Kaspire Wallet, version name is 0.5.10 P2SH Accounts; no Test
suffix. ZIP integrity checked, same manifest key/extension ID retained.
SHA-256: `8ff2b0f35d6b1f4245580865e6a9d749e8c2f46cda99249c7b051e1a3c721c0f`.

Local packages only. No public manifest, website, Git push or store submission.

### Extension 0.5.11: P2SH submission and popup-width hotfix

- Root cause: 0.5.10 posted to /api/local-node/transactions. The gateway strips
  /local-node only for GET, so that POST was forwarded to an invalid upstream
  path. The extension ignored HTTP rejection and repeatedly waited for a payment
  that it had not successfully submitted. Read-only checks confirmed that the
  deployed gateway matches the repository routing; no user payment was submitted
  or replayed by the build agent. No real transaction IDs are stored here.
- POST now uses /api/transactions, matching Android. UTXO reads, saved-payment
  validation and exact-ID/is_accepted confirmation stay pinned to /api/local-node.
  The exact encrypted pending bytes are re-persisted before any possible POST.
- Definite 4xx rejections perform one acceptance-race check, then immediately
  show HTTP status and a bounded/sanitized backend reason instead of a misleading
  30-second wait. Interrupted responses, 5xx and explicit already-known replies
  still use bounded own-node checks; their submission reason is retained in the
  pending UI if confirmation remains unavailable. A mismatching returned ID is
  no longer swallowed. No rejection authorizes a replacement or erases the journal.
- Remove P2SH html/body viewport-size overrides. Receive and P2SH inherit the
  same fixed popup width. Chromium tests also simulate a transient 320px viewport
  while switching and require unchanged body width in all four themes.
- Tests now assert the exact POST URL rather than accepting any URL in mocks.
  They cover 400/401/403/404/405/422 rejection without a confirmation-wait loop,
  ID mismatch, acceptance races, ambiguous failures, and recovery of a saved
  0.5.10 journal through the corrected route without approval or re-signing.

Validation: all 136 extension unit tests pass; TypeScript and git diff checks
are clean. P2SH Chromium UI tests pass in Midnight, HUB21, Glacier and Neptune;
the full actual-extension Chromium smoke test passes, including encrypted P2SH
backup/restart preservation and dApp/pending-reveal regressions. The packaged
Rust/WASM signer is byte-identical to 0.5.10; this is a transport/UI-only fix.

Package: `apps/browser_extension/artifacts/kaspire-extension-0.5.11.zip`.
SHA-256: `37eea1079fe5969ce2821edfb35b2115b6b707dd162c74e4e2a121fb2084d18e`.
Same manifest key and extension identity; install as an update/reload, NOT by
uninstalling the existing extension. Then use Check payment status for the saved
payment. Android, public website/manifests, Git and Chrome Store are unchanged.
