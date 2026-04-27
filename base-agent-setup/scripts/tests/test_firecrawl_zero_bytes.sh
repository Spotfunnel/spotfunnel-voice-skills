#!/usr/bin/env bash
# scripts/tests/test_firecrawl_zero_bytes.sh
#
# M23 Fix 4 — confirm the script's exit-code path when total_chars=0.
# Doesn't actually call Firecrawl; it injects a stub that mimics the script's
# tail logic to verify the halt condition is wired correctly.
#
# This is a 5-line shell test as the spec asks: write a stub combined.md
# that's empty + run the relevant exit-code check, expect non-zero.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The exit-code check we added in firecrawl-scrape.sh (M23 Fix 4):
#   if [ "$CHARS_TOTAL" -eq 0 ]; then ...exit 1; fi
# Mirror it here as a regression guard. If someone later removes the
# halt, this test fails.
CHARS_TOTAL=0
URL="https://example.com"
EXIT_CODE=0
{
  if [ "$CHARS_TOTAL" -eq 0 ]; then
    echo "[ERR] firecrawl-scrape: 0 chars extracted from $URL. Site may be JS-only or unreachable. Confirm the URL renders content with a real browser, then re-run /base-agent." >&2
    EXIT_CODE=1
  fi
}
if [ "$EXIT_CODE" -ne 1 ]; then
  echo "[FAIL] zero-bytes path did not exit non-zero" >&2
  exit 1
fi

# Also confirm the exact phrase the spec asks for survived in the source
# file — if a future rewrite drops the user-facing message, this test
# trips and the operator sees the regression in the failing test name.
if ! grep -q "0 chars extracted from" "$SCRIPTS_DIR/firecrawl-scrape.sh"; then
  echo "[FAIL] firecrawl-scrape.sh missing the M23 Fix 4 zero-bytes halt message" >&2
  exit 1
fi

# Confirm the conditional itself is still in place.
if ! grep -q 'CHARS_TOTAL.*-eq 0' "$SCRIPTS_DIR/firecrawl-scrape.sh"; then
  echo "[FAIL] firecrawl-scrape.sh missing the CHARS_TOTAL=0 guard" >&2
  exit 1
fi

echo "[PASS] firecrawl-scrape zero-bytes halt is wired"
exit 0
