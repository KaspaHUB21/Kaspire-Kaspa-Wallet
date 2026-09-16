# dot.k marketplace — Android implementation

Release: Android 0.11.32, build 104. Native deterministic builder, Android/JNI
authorization, own-node verification, Flutter marketplace and directory are
enabled by default. The user confirmed actual listing and purchase flows;
accepted cancellation and sale transactions were independently read from the
node. No real transaction was broadcast by the coding agent. This is not an
independent security audit. Back up the wallet and listing recovery code.

Builds can disable the feature with `--dart-define=KASPIRE_DOTK_MARKET=false`.
The `/market-test-v1` API path is retained for compatibility with earlier APKs.
Published listings show a disabled Published action. Test-build notes below
are retained as historical evidence, not the current distribution status.

## Agreed economics and ownership

- Prices are gross KAS amounts expressed as integer Sompi.
- User-selected minimum listing price: **10 KAS**, enforced by Rust, UI and
  directory admission. This also avoids tiny marketplace-fee outputs exceeding
  storage-mass limits (a 1 KAS gross-price fixture failed that limit).
- Marketplace fee: `floor(price_sompi * 21 / 1000)`; seller receives the rest.
- Recipient: `hub21.kas`, resolved at listing creation and pinned in that listing's
  terms and covenant. Public KNS resolution on 2026-09-15 returned
  `kaspa:qraed0llukpgfvnnhsctmrsrm4m9vkeqyvg6ek82vtq7gmh99c8qcz9atrgz6`.
  KNS resolution relies on its indexer; it is not a consensus name-ownership
  proof. The native confirmation displays the actual fee address. The isolated
  directory also admits only its configured fee recipient. If the name changes,
  update directory admission policy deliberately; existing covenant terms never
  change. Unit fixtures use unrelated public test keys.
- Network fees are additional to the purchase price.
- A listing transfers the deed into a unique sale covenant (owner type 4), not
  to a marketplace-controlled private key. Listing and cancellation are on-chain
  operations and incur fees. This is non-custodial on-chain escrow, not a PSKT-only
  off-chain listing.
- A provisional 1 KAS sale reserve is returned to the seller when purchased or
  cancelled. The separate existing 1 KAS dot.k deed bond stays with the name.
  Reserve requirements and fee selection must still be validated across cases.

## Prototype structure

`crates/kaspa_secure_core/src/dotk_sale.sil` binds the seller, integer price split,
fee script, dot.k registry and exact name deed template. Each listing has a unique
covenant ID derived from its funding outpoint and sale output. The deed stores
that ID as its owner.

Spending uses input 0 for the deed, input 1 for the sale covenant and subsequent
inputs for funding. The covenant enforces the exact successor deed at output 0,
preserves its bond, and extinguishes the sale covenant. A purchase requires a
buyer ALL signature, transfers the deed to that buyer, and pays seller and fee
outputs. Cancellation requires the seller's ALL signature and returns deed and
sale reserve to the seller.

## Evidence available

Run `cargo test -p kaspa_secure_core --lib --offline` (61 tests at this stage),
and `flutter test --no-pub` in `apps/mobile_flutter`.

Local tests execute the embedded deployed dot.k deed bytecode and the new sale
bytecode together with the pinned Rusty Kaspa engine. They cover:

- Exact fee calculation and range validation.
- Covenant bytecode binding to name, seller, price and fee recipient.
- Listing genesis and derived sale covenant ID.
- Atomic purchase and cancellation.
- Underpayment, redirected seller/fee outputs, changed bond and wrong deed.
- Non-ALL signatures and foreign covenant IDs.
- Effective mass limits for the buy/cancel fixtures.
- Builder-generated list, buy and cancel transactions signed and VM-validated.
- Review-hash mismatch, wrong signing key, forged cells, duplicate outpoints,
  fragmented funding and 10 KAS purchase boundary.
- Flutter recovery persistence, publication failure preserving recovery data,
  search pagination and malformed offer metadata.

Fixtures use synthetic UTXOs and publicly specified test keys. They are not
network acceptance, mempool-policy, adversarial audit or end-to-end evidence.
Example 100 KAS fixture masses: buy 49,014; cancel 48,815 against reference limit
500,000. These are mass units, not a quoted network fee.

## App and directory behavior

- Access: Assets → dot.k Marketplace, or Settings → HUB21 Toolbox.
- Browse has search; My names lists holdings; My listings contains recovery
  entries including pending or spent historical listings. Availability is
  rechecked before review and independently in Kotlin before signing.
- Each review includes gross price, seller proceeds, fee recipient, fee,
  reserve, deed bond, KAS change, covenant ID, effective mass and raw unsigned
  transaction JSON. The native authentication prompt uses the Rust review.
- Save the recovery code before submitting a listing. Publication is attempted
  automatically after broadcast; Publish remains available to retry. The screen
  refreshes after operations and on explicit Refresh, without periodic polling. After confirmed
  cancellation, My names can be used to list again with a new price.
- Spent local listings are classified using dot.k history as discovery hints and
  accepted transactions from the own-node gateway as evidence. Exact listing
  outpoints, deed bond/registry and seller/commission outputs distinguish Sold
  from Cancelled. Errors remain Status unavailable, not an inferred sale.
  Completed entries retain history but no recovery/publish/cancel actions.
- Cancellation does not require the directory. Restore listing code plus the
  controlling wallet when needed; the wallet backup alone does not contain new
  listing terms. The directory can help rediscover published seller listings.
- `/market-test-v1` is a separate directory service (legacy-compatible path).
  It stores only public terms/transaction IDs, validates admission against node
  data plus the native descriptor, limits body/capacity and retires known spent
  offers in a background sweep. Read hints can be stale until a sweep; the app
  rechecks live state before approving any transaction. No broadcast/private-key
  endpoint exists. No URL/address access logs are enabled for its nginx route.
- Native node verification uses the fixed own-node HTTPS gateway, not a URL
  supplied by a marketplace. This is an endpoint trust assumption, not SPV.

## Remaining assurance and operations work

1. Validate listing, buy and cancel across prices, funding fragmentation,
   storage mass, compute limits, dust and fee estimation. Add adversarial tests
   for authorization, input/output duplication, concurrency and changed state.
2. Independent review of the covenant and integration; replay/race and device
   tests, including cancellation after directory loss and restoration on a new
   phone. Signature/VM tests alone do not prove full mempool policy acceptance.
3. Expand directory capacity and stale-offer handling as traffic grows. Automatic
   publication and explicit retries are implemented; outage recovery still
   requires further device coverage.
4. Verify the signed APK on devices and retain the existing Android signing
   lineage. The user approved the public build 104 release after private tests.

Existing wallet signing methods are unchanged. Distribution changes for build
104 are documented in `release-v0.11.32.md`.

## Build 102 regression follow-up

- APK: `artifacts/dotk-market-test/Kaspire-Android-dotk-market-v0.11.32-test-build102.apk`.
  Version `0.11.32-market.2`, build 102. SHA-256:
  `360f1f9f8305235b6e2be60e5bd6df443c1b965d87309e00e1f3edb825971c4f`.
- Flutter analyze: no issues; all 121 Flutter tests passed, including eight
  marketplace service tests. No public release or update manifest changed.
- `block21.k` was already cancelled by accepted transaction
  `d68b8eed28e28d77f8b32e9b50c1c14cb4ff4460e348c8db13cbe44456118b76`.
  The reported failure was a repeated cancellation offered by stale local UI.
- `gothmil.k` was sold in accepted transaction
  `5987a1e61859f011eb4f644b55c2311f63f36febbaf0fcba8b441ca8e8d98d2c`.
- Build 102 uses the current source-default Reown project configuration. Build
  101 accidentally overrode it using an older build-environment value. Personal
  message signing code is unchanged; device pairing still needs user testing.
- Flutter tests cover exact completion evidence, unrelated/malformed payouts,
  history discovery and unavailable-node behavior.

## Test artifact

Build 103 (`0.11.32-market.3`) refines the marketplace UX: automatic publication
is retained, and failed publication explicitly warns that the offer is not in
Browse and opens My listings with a Publish instruction. My listings groups
active offers first, unresolved offers next, and completed history last, newest
first within each group (local recovery insertion order). Browse supports exact
sompi price sorting in both directions. Periodic ten-second polling is removed.
Legacy recovery imports have no historical creation timestamp and use their
local insertion order. No contract, signing or marketplace fee changes.
Validation: Flutter analyze clean; all 123 Flutter tests pass, including ten
marketplace tests and new ordering/price-sort regressions.

- APK: `artifacts/dotk-market-test/Kaspire-Android-dotk-market-v0.11.32-test-build101.apk`
- Version `0.11.32-market.1`, code `101`, package `space.kaspire.wallet`, min SDK
  30 / target 36; ARM64 and ARMv7 native libraries included.
- SHA-256: `87517bddf613250122d28621303f8c2f2d4af9ebf8b83ee3374bf65929a3bd05`.
- Existing v3/v3.1 lineage verified independently for API 30–32 and API 33+.
- Public latest APK still has SHA-256
  `10b0e419a9b26341be14ecc767c249ffa0c6105f9b15e96da579038019b6c72e`.
- Test directory systemd service: `kaspire-dotk-market-test`, loopback port 8138,
  separate dynamic user and `/var/lib/kaspire-dotk-market-test` state directory.
  Public route `/market-test-v1/`; nginx pre-change backup is under
  `artifacts/dotk-market-test/nginx.before.conf`.
