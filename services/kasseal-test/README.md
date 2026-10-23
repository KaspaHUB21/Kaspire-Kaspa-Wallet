# Kasseal Android integration

Public Android 0.11.60 build 203 enables Mainnet and TN10 under Swap, in the
order KaspaRocket, Kasseal, KRON. Earlier internal builds 199–202 used TN10 only.
Mainnet runs in a separate immutable-network process on loopback 8175;
TN10 remains on 8173. The existing DEX gateway mounts `/kasseal-mainnet` and
`/kasseal` respectively. No nginx changes are required.

- SDK `@kassealhq/sdk` 0.1.1, pinned by npm integrity in `package-lock.json`.
- Source inspected at `Sealkaspa/kasseal-sdk@71d25563a594d47a5d421646a8a4b02df2eec848`.
- Mainnet API: `https://app.kasseal.com/v1`; TN10: `https://testnet.kasseal.com/v1`.
- Both are public; no API key or wallet login is needed.
- `template-pins.mjs NETWORK` reproducibly emits native template allowlists
  from integrity-verified SDK artifacts. Mainnet venue pins are distinct from TN10.
- Mainnet profiles are `kasseal-mainnet-swap-v1` / `kasseal-mainnet-prepare-v1`.
  The sender prefix, reviewed network and fixed native profile must agree.
- Mainnet UTXOs and confirmations come from Kaspire's synchronized, UTXO-indexed
  node. Saved journals and history keys are network-specific.
- Loopback planner on 8173: public token pages, quotes and unsigned plans only.
- Existing DEX gateway mounts it at `/dex-test-v1/kasseal`; no nginx changes.
- `GET /apk` serves only the fixed signed internal APK with an attachment filename.
- Native profile `kasseal-tn10-swap-v1` rejects Mainnet, arbitrary programs,
  foreign ownership, non-ALL signatures and changes to economic limits.
- Sixty-six TN10 curve variants, pool and reference token are fingerprinted from
  the SDK. Only the compiled state and the SDK's exact creator slots are masked.
- The planner verifies each launch proof and requires independent graduation
  confirmation before pool trades. Plans use confirmed heads rather than pending
  tip chains. The app separately resolves complete live UTXOs through the fixed
  `/utxos` TN10 gateway before review and before signing. Its independent,
  synchronized UTXO-indexed TN10 wRPC node is not operated by Kasseal and includes
  explicit covenant IDs (or null for ordinary funding), amounts, scripts and DAA.
  No historical-origin lookup is needed: pruned transactions may return 404 even
  when their outputs are still spendable. Missing origin history during recovery
  never proves a conflict and does not block resubmitting the exact saved bytes.
- SDK zero DAA metadata is replaced with node data before preparing the native
  review. The same data is checked again before signing; amounts/SPKs/CIDs are
  never replaced with provider guesses.
- Rust binds the review hash and runs every signed covenant script locally.
- Signed swaps are encrypted before submission; recovery checks the independent
  node and reuses exactly the same bytes. Only a confirmed competing spend of an
  exact input permits archiving an obsolete swap and refreshing the quote.
- Whole tokens (zero decimals), whole lots on curves; refundable 5 KAS token-cell
  deposits are shown separately. The network fee ceiling is 2 KAS.

Build 202 supports partial sales that need a split or merge. The SDK builds only
the first live preparation step; the `kasseal-tn10-prepare-v1` Rust profile permits
only pinned reference tokens owned by the same wallet, exact token conservation,
SIGHASH_ALL, bounded deposits/debit/fees, and no venue or external recipient.
Every step is independently reviewed, signed, simulated, encrypted and confirmed
before the next step is rebuilt. `/prepared` waits for Kasseal to index the exact
confirmed preparation, never interpreting confirmation as a completed sale.
At most eight preparation steps are offered per uninterrupted flow. Later steps
can be continued with a fresh quote. Older APKs do not opt in to new profiles.

Sale review separately reports trade income after protocol fees, returned token
deposit, network fee and the actual net wallet increase. Existing funding/change
is not income. Rust cross-checks all figures and does not allow a returned deposit
to mask trade proceeds below the locally approved minimum.

The Mainnet Kascov display fallback reads a covenant-bound verified KCC-23
declaration before the technical indexer alias. This never changes signing
programs or token identity. US thousands/decimal display formatting is shared
across Kasseal/KRON, Rocket, marketplace balances and EVM balances; raw machine
amounts and editable input strings remain ungrouped. Sompi formatting uses exact
integer arithmetic, including values above the floating-point safe integer.

Build 201 adds a separate, encrypted local swap history (including earlier
ActivityStore entries), distinct KAS buying budget/token selling balance labels
and Kasseal's original seal logo. Mainnet dot.k Browse defaults to newest chain
listing time and has optional multi-select bare-name length groups (1–3, 4–6,
7–9, 10+). Filters and sorting precede visible-page slicing.

Recovery checks all input-address groups, including every outpoint sharing an
address, and pages up to 1,000 history items per address/100 pages per search.
Repeated pages, missing origins and exhausted limits explicitly mean unknown,
never proof of obsolescence. Only an accepted exact competing spend, followed
by a recheck of the original payment, can archive a journal. An unknown lookup
does not prevent retrying the exact signed bytes. Android and extension P2SH
activity expose Load more and incomplete-history state, merging/deduplicating
transactions across pages and addresses.

Validation: the unchanged core previously passed 126 Rust tests (including real
unsigned curve buy and synthetic pool buy/sell execution). Build 201 passes 131
Flutter tests, 45 extension recovery/P2SH tests and 6 dot.k server tests; the SDK
also has 4 integrity/node-serialization tests. A public unsigned curve-buy plan reproduces the old
funding-origin 404 and verifies every input against live TN10 state. No wallet
transaction was signed or broadcast in this check.

Build with the existing Android release wrapper, plus
`--build-name=0.11.60 --build-number=203`.
Use the normal Android SDK/JDK paths. Both ARM64 and ARMv7 cores must be rebuilt first.

Build 202 validation: 128 Rust tests, 152 Flutter tests, 46 focused extension
tests, and 5 SDK tests pass. Split, merge and curve-sell fixtures execute signed
synthetic transactions in the local script engine; no real funds were signed
or broadcast. A live public-holder HTTP plan independently produces an unsigned
split preparation. Release signing and client configuration are verified for
both packaged Android ARM architectures.
