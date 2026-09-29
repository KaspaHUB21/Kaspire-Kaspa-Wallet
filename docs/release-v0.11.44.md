# Kaspire Android 0.11.44

This Android hotfix corrects the native signature script used when minting a
Covenant Dragon egg.

## Covenant Dragons

- Use the complete P2PK signature script returned by the pinned Rust core
  without incorrectly wrapping it in a second data push.
- Execute the finished genesis transaction locally with the Kaspa/Toccata
  script engine before it can be submitted to the node.
- Reject malformed or otherwise invalid Covenant Dragon transactions locally
  instead of asking the user to approve a transaction that consensus will
  reject.

## Security and compatibility

- Preserve the package ID, Android 11+ support and established Android signing
  lineage so existing installations can update normally.
- Keep transaction construction, validation and signing inside the pinned native
  Rust core and Android approval boundary.
- Keep the signed Android update manifest on the pinned Kaspire download host.
