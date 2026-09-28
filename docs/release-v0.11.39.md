# Kaspire Android 0.11.39

Urgent KAS send hotfix:

- Restores KAS transaction signing for imported private-key wallets and other single-address wallets.
- Keeps multi-address KAS balance aggregation and spending for wallets using rotated receive addresses.
- Adds regression coverage for imported private-key signing, ordinary subwallets, and aggregated HD accounts.

Users of Android 0.11.38 (Build 119) should update to this release immediately.
