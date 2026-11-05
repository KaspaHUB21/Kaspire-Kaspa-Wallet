# KForge Buy-input correction — Android test 0.11.92 / 237

Buy now always accepts a KAS trade amount (up to eight decimals), on both
Mainnet and TN10 and in both curve/pool phases. Sell still accepts whole token
amounts. The previous curve-only token input was a UX mistake, not a required
wallet-facing protocol model.

The provider's curve prepare route still expects a lot count. Kaspire derives
the largest affordable count internally using exact integer/sompi arithmetic
and the freshly loaded linear ladder. It does not use the rounded display
price, floating point, or the provider's claimed token output as authority.
Below-minimum budgets fail before prepare/signing and report the minimum KAS
trade amount. Curve sells keep their existing lot constraint.

The entered amount is the trade budget, matching the preexisting pool input:
network fees, protocol fees where added, and any new token-cell reserves are
shown separately and included in the explicit all-in wallet payment. It is not
silently redefined as an all-in payment cap. Lot rounding is labelled as KAS
not used for tokens, not as a falsely guaranteed net wallet remainder.

The request carries `buyBudgetSompi`. The native core requires it for new buys,
checks pool input equals it, checks curve cost does not exceed it and that the
builder did not omit an additional affordable curve lot. The budget, verified
trade use, unused trade budget, actual tokens and exact wallet debit are bound
into the approved review. Signing still verifies the complete contracts and
all inputs in the local VM. Existing signed recovery bytes are retained; they
are not re-signed or discarded due to this UI correction.

Tests include exact-lot and one-sompi boundaries, both networks, curve/pool
Buy/Sell switching in every theme, real captured Mainnet quotes through the
app/native adapter and full synthetic local VM execution. No funded swap is
executed by these tests. Extension, iOS, public APK/update manifest, website
content and GitHub releases are unchanged; this is a direct-download test APK.

Verification: 163 native core tests and 1,121 Flutter tests passed (18 optional
live/snapshot tests skipped). The targeted KForge run passed 124 tests. The
analyzer reports no errors or warnings, only informational style diagnostics.

Download: `https://kaspire.kaslab.space/downloads/Kaspire-Android-v0.11.92-KForge-mainnet-test.apk`

APK SHA-256: `a3a151ab1346252aff2384c2c86e46b8320ea19344c940c694f55c281da6bd68`.
The actual signed APK's ARM64 and ARMv7 libraries match the verified new native
builds; its native KAS-budget guard and corrected UI are present. Existing
Android signing identity, lineage and public-client configuration are verified.
