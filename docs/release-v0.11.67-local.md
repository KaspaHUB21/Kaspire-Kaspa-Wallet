# Kaspire Android 0.11.67 — local Borrowed Receive build

Build 210, package `space.kaspire.wallet`, ARM64 and ARMv7, Android 11+.
Historical preparation notes from before public promotion. The public release
and signed update channel are documented in [release-v0.11.67.md](release-v0.11.67.md).

- Standard KCC20/KaspaRocket transfers reuse a live recipient cell when its
  amount-threshold policy explicitly allows the increase. Preserve its ownership,
  full guard, extended identity, existing tokens and KAS deposit. Do not sign the
  borrowed input. Native deterministic rebuilding, review binding, local VM and
  live-node checks remain in place.
- New standard receiving/change cells allow positive future borrowed receipts.
  A disabled or separately authorized recipient policy is never bypassed.
  Compound plans reserve the additional final receiver-input slot and borrow only
  in the final payment, not the sender's consolidation steps.
- Existing owner-authorized cells with a borrowing policy can be sent normally.
  The review states whether a receiving cell was reused or a new cell is needed.
  Kasseal and legacy KRON production integrations remain unchanged.
- Activity resolves verified KCC20 units and parameterized actor receipts. BTE's
  250000-unit transfer displays as 250 tokens with three decimals. Verified
  receipts take priority over old fallback amounts, including a legacy ticker
  alias for the same covenant identity.

## Verification

- **677** Flutter tests and **134** native Rust library tests passed in isolated,
  offline, bounded environments. Focused changed-file analysis passed.
- Native libraries rebuilt for both Android ABIs. Android public client/Reown
  configuration check passed against the resulting APK. Read-only public Rocket
  read/trade and Kasseal unsigned-planner readiness checks passed.
- APK version 0.11.67 / 210, alignment and APK v3 release signature verified.
  Existing release certificate and rotation lineage preserved. No funded wallet
  or real transaction was used for validation. Physical device testing remains.

APK SHA-256:
`0cbcd76ffaeb69c78dfb8bfdb3f5eb0997779ca2dbb5d79c36cb913a0283d55a`

Release certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
