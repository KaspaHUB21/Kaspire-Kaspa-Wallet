# Kaspire Android 0.11.62 — Token explorer link hotfix

- Fix Check on Explorer for KaspaRocket/KCC20 token details: use the explorer's
  `/kcc20/<covenant-id>` route instead of the KRC20 `/token/` route.
- Prefer the actual covenant ID over a technical asset alias.
- Keep existing KRC20 explorer routes and ticker fallback unchanged.

The token transfer and swap flows are unchanged. Android signing certificate,
signing lineage and update-manifest trust remain unchanged.

Validation: all 630 Flutter tests pass, including twelve focused link and
token-detail/theme regressions. Static analysis of the changed files reports no
issues. The reported Mainnet explorer URL returns HTTP 200. No transaction was
signed or broadcast to validate this display/navigation-only change.
