# Kaspire Android 0.11.59

Urgent KaspaRocket swap-recovery hotfix:

- Restore a usable Refresh quote flow when the live pool changes before a swap executes.
- Recognize already-saved obsolete swaps from Android 0.11.58: independently confirm a competing spend on Kaspire's own node, archive the obsolete signed bytes, and release the stale swap lock.
- Preserve recovery for uncertain broadcasts, unavailable node data, already accepted swaps and partially completed plans. A timeout, HTTP 409 or missing transaction alone never discards a signed swap.
- Show the actual provider rejection details instead of mapping every conflict to the same generic pool-change message.
- Keep the Android signing lineage, pinned download host and signed update manifest unchanged.

The browser extension is unchanged.
