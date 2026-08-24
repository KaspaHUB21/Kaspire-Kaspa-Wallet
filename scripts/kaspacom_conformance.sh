#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

cd "$REPO_ROOT"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/kaspire-cargo-target}" \
  cargo test -p kaspa_secure_core

cd "$REPO_ROOT/apps/browser_extension"
npm run check
npm test
npm run package
npm run test:browser

cd "$REPO_ROOT/apps/mobile_flutter"
"$FLUTTER_BIN" analyze
"$FLUTTER_BIN" test

echo "Kaspire local KaspaCom conformance suite passed."
echo "Live KCC20/Kaspiano TN10 evidence must still be recorded separately."
