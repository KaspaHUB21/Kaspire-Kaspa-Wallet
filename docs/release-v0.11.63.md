# Kaspire Android 0.11.63 — Global Kasseal token search

- Search the full Kasseal catalogue by ticker or name through its official
  `search` API parameter, instead of filtering only the first 20 loaded tokens.
- Exact covenant IDs resolve the requested token directly. Opening a held
  Kasseal token no longer depends on that token appearing on the first page.
- Debounce typing, preserve the query while loading more results and reset
  pagination when the search changes or is cleared.
- Ignore delayed results and errors from older queries, including a first-page
  request still loading when the user starts searching.
- Keep verified-token display requirements, launch-proof checks and native
  transaction/signing validation unchanged.

Validation: all 636 Flutter tests and 11 server/SDK tests pass. The reported
UNNACHOD token is found through the live Mainnet route in both cases and by
exact covenant ID. No transaction was signed or broadcast to validate this
catalogue/navigation fix. The native signing core and Android trust chain are
unchanged.
