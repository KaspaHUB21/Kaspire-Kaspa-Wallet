# Kaspire Android 0.11.73 — Forge JSON compatibility and accessible recovery

Build **218**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.72/build 217**. Extension **0.5.27**, Windows, iOS and their
update channels are unchanged. Forge remains **Testnet 10 only**.

## Fix the actual Forge JSON rejection

- Supply the required top-level transaction `id` in signed SafeJSON sent to
  Forge. Kaspire's native signer returned the computed ID separately; the
  previous adapter omitted the field required by Forge's deserializer.
- Re-prepare the original plan with the existing Rust core and compare its
  computed transaction ID and saved review before adding the metadata. Require
  every signed term/embedded UTXO to match the original plan, apart from the
  selected signature witnesses. Reject conflicting IDs or changed terms.
- Repair existing signed receipts in the same way without re-signing or
  changing their on-chain transaction, signatures, outputs or guaranteed payout.
- Preserve submission errors, durable journals and same-transaction retry.
  Do not reinstate the removed direct-node deposit fallback.

## Make saved orders and recovery accessible

- Add a prominent saved-order/recovery card to the Forge catalogue and token
  trade screen, independently of the server's registered-order list.
- Show local loading and failure states with Retry instead of silently hiding
  journal errors. Distinguish an empty Forge server list from local recovery.
- Reopen the exact blocking saved order from Review instead of attempting to
  build a second order or showing only the blocking error. Keep all themes,
  narrow layouts, late local results and reopening covered by regression tests.
- Show status checking for signed orders even if submission failed before the
  deposit stage.

## Recover an unsubmitted KAS buy safely

- Preserve the existing server-independent contract cancellation for a
  confirmed deposit.
- For an **unconfirmed, single-step, wallet-owned P2PK KAS buy only**, offer an
  explicitly confirmed self-payment spending the exact original funding inputs
  back to the same wallet. This invalidates the saved deposit; it does not rely
  on a missing transaction or expired build ID as proof that it is safe to retry.
- Disclose the **0.1 KAS network fee** in the recovery confirmation. Verify the
  live inputs before signing and use the existing ordinary P2PK signing path.
  No token-input, sell or split-plan signing support is broadened by this path.
- Preserve the signed cancellation and journal. Unblock new orders only after
  independent acceptance of the exact cancellation and its required return to
  the wallet. Unknown, missing or mismatched proofs remain pending, not cleared.
- If the original deposit wins the input race, preserve the obsolete signed
  self-return and reopen ordinary contract recovery instead of retrying an
  impossible cancellation or allowing a replacement swap.

## Verification and limits

- **69 focused service/widget tests passed**; targeted static analysis is clean.
- Full regression: **802 Flutter tests passed** (3 opt-in live suites skipped),
  **145 Rust library tests passed**.
- Live unsigned curve buy/sell and pool buy builds pass native review. The
  adapter test uses actual **Rusty-Kaspa 2.1.0** SafeJSON deserialization: the old
  missing-ID envelope fails, the corrected envelope parses with the same
  computed ID and unchanged dummy witnesses. The self-return plan also passes
  native review. API submit is intercepted in this test; no real order is sent.
- The Rust signing library and contract policies are unchanged. The read-only
  diagnostic binary adds an opt-in unsigned self-return inspection mode.
- The final APK was checked for **0.11.73/build 218**, the new recovery/identity
  and race-handling code in both ABIs, unchanged native signing libraries,
  required WalletConnect/Rocket client configuration, 16 KB alignment and its
  v3 signature. Signing certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

No user order was remotely resubmitted, invalidated or cancelled. No funded
Android-device settlement/refund is claimed; the parser/recovery fixes do not
guarantee that every possible upstream Forge failure is resolved.

## Website and both Android update routes

Update the official APK, website version/checksum and signed Android manifest.
Keep the official-site download and matching GitHub in-app download, Android
installation approval, existing signing identity/lineage and manifest trust.
Release notes remain GitHub-only, not inline in website download cards.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.73.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.73/Kaspire-Android-mainnet-v0.11.73.apk)
- APK SHA-256: `4d48e380b977695eac1a59f1ad392ff35c0f1e56a826ef6fd654455249062f47`.

Install over the existing app; do not uninstall or clear app data. Keep a
current encrypted backup. Open the saved recovery card before creating another
trade from an affected wallet.

For an affected wallet, use **Swap → KasForge → Open saved order / recovery**.
Review also opens the exact blocking saved order. Retry the saved submission
with its corrected metadata, or use **Cancel / recover unfilled order**. After
recovery, check its status for independent confirmation before starting again.
