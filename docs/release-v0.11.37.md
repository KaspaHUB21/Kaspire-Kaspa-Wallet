# KaspaRocket TN10 DEX integration and security hardening

This release introduces native KaspaRocket DEX support on TN10, strengthens wallet locking in the browser extension, expands secure PSKT support, and adds several transaction, backup and update-integrity protections across Kaspire.

## KaspaRocket DEX on TN10

KaspaRocket is now integrated directly into K-Agora in both the Android app and browser extension.

- Browse and search supported KaspaRocket KCC20 tokens.
- Buy and sell tokens using live DEX quotes.
- Display token images, balances, prices, pool liquidity and 24-hour statistics.
- Display both the token covenant ID and pool covenant ID because KCC20 tickers are not unique.
- Show KaspaRocket tokens directly under TN10 assets.
- Display personal KaspaRocket swap activity.
- Present a complete secure review before signing.
- Show a persistent transaction receipt with swap and transaction details after completion.
- Validate available KAS and token balances before preparing a swap.
- Replace technical conflict messages with understandable insufficient-balance errors.
- Use the SDK 0.1.6 `amountTokensDisplay` value consistently throughout the app and extension.
- Correct token decimal handling in balances, quotes, reviews and receipts.
- Add safe bottom spacing to all Android DEX screens so controls are not obscured by the system navigation bar.

KaspaRocket trading remains restricted to TN10. Mainnet assets and transactions are unaffected.

## KaspaRocket transaction security

Kaspire does not blindly sign transaction plans returned by the DEX.

- KaspaRocket plans use a dedicated testnet-only PSKT security profile.
- Token and liquidity-pool covenant IDs are bound to the reviewed transaction.
- Expected sighashes are independently recalculated and verified.
- Only `SIGHASH_ALL` is accepted for KaspaRocket swaps.
- Prebuilt signature scripts are restricted to verified KaspaRocket covenant inputs.
- Signature placeholders and offsets are bounds-checked before signing.
- Fee summaries and swap directions are checked for inconsistencies.
- Wallet inputs, wallet outputs, network fees and covenant outputs are shown during review.
- Account, network and reviewed transaction state are checked again immediately before signing.

## Browser extension security

- Stored wallet state contains only explicitly permitted public metadata.
- Decrypted vault data is kept only in volatile extension memory while the wallet is unlocked.
- Legacy plaintext session fields are removed automatically.
- Locking Kaspire invalidates every pending signing approval.
- Approvals are bound to the active unlock generation, account, network and dApp permission state.
- A locked dApp request now asks the user to unlock Kaspire before transaction preparation continues.
- Concurrent and duplicate approval requests are limited.
- Imported legacy backups are checked against their derived wallet addresses before being accepted.
- Backup size limits protect the extension against oversized or malformed encrypted backup payloads.

## Android security

- Private-key and recovery-phrase exports always require fresh device authorization.
- Wallet ownership checks now compare complete canonical addresses.
- Android 15 and newer additionally require the device to be unlocked before the hardware-backed vault key can be used.
- Oversized or malformed encrypted backup payloads are rejected before expensive decoding or key derivation.
- Kaspa and Layer 2 broadcasters must return the transaction ID expected from the locally signed transaction.

## PSKT and dApp compatibility

- Improved sign-only PSKT support for marketplace workflows.
- Added controlled support for seller offers funded later by a buyer using `SIGHASH_SINGLE | ANYONECANPAY`.
- Preserved unknown safe PSKT JSON fields needed by external applications.
- Added restricted support for verified covenant signature-script templates.
- WalletConnect account events are filtered to accounts actually approved for the connected session.
- Signing requests become stale after an account, network, permission or lock-state change and must then be rebuilt.

## Update and distribution integrity

- The Android updater remembers the highest verified signed release and rejects manifest rollback attempts.
- Publication timestamps are checked to prevent signed-manifest rollback.
- Website deployment verifies the signed update manifest before publishing an APK.
- The download directory retains only the current verified Android APK.
- Existing Android signing lineage is preserved for normal updates from previous Kaspire releases.

## Additional hardening

- The dot.k marketplace backend now requires an explicitly configured and validated fee recipient.
- Listing records with an unexpected marketplace fee recipient are rejected.
- TN10 KCC20 asset loading and K-Agora routing have been improved.
- Transaction broadcaster responses without a valid transaction ID are rejected.
