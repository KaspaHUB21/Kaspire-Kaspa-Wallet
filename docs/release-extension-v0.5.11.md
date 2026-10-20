# Kaspire Browser Extension 0.5.11 — P2SH accounts and Covenant Vaults

- Open Receive KAS → P2SH account for a separate Mainnet KAS balance using KIP-22 addresses from a seed-based HD wallet.
- Hide the spending public key until its outputs are spent; create fresh P2SH change and use Max with automatic network-fee deduction.
- Review recipient, amount, fee and change through the same locally rebuilt Rust signing core used by Android.
- Keep issued/retired addresses and pending signed transactions inside the encrypted wallet and portable recovery backup.
- Resume an interrupted payment using its exact saved bytes; require matching transaction ID and own-node acceptance before confirming success.
- Fix P2SH submission routing and expose explicit HTTP rejections immediately; do not silently enter repeated confirmation waits.
- Keep Receive and P2SH popup widths identical in every theme.
- Keep P2SH inaccessible to dApp provider commands and bind approvals to the current unlock session, wallet, account and network.
- Add native Time Lock and Dead Man’s Switch Covenant Vaults with portable recovery files protected by Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87.

P2SH does not replace Schnorr signatures with a post-quantum signature scheme. Keep a current encrypted backup, avoid retired receiving addresses and do not use the same P2SH account on multiple devices at once.

This version is live in the Chrome Web Store. When updating an unpacked installation, replace/reload the existing extension; do not uninstall an installation with saved payments or wallet data.

ZIP SHA-256: `37eea1079fe5969ce2821edfb35b2115b6b707dd162c74e4e2a121fb2084d18e`.
