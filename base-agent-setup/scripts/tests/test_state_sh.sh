#!/usr/bin/env bash
# scripts/tests/test_state_sh.sh
#
# M8 smoke test — runs the Supabase-backed branch of state.sh end-to-end
# against the live operator_ui schema, then cleans up.
#
# Required env (loaded from the repo root .env if present):
#   SUPABASE_OPERATOR_URL
#   SUPABASE_OPERATOR_SERVICE_ROLE_KEY
#
# Exit 0 on success. On any assertion failure, exits 1.
#
# Usage:
#   cd base-agent-setup/scripts/tests && bash test_state_sh.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

# Auto-source the repo root .env if it exists and the env vars aren't set.
if [ -f "$REPO_ROOT/.env" ] && [ -z "${SUPABASE_OPERATOR_URL:-}" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +o allexport
fi

: "${SUPABASE_OPERATOR_URL:?SUPABASE_OPERATOR_URL must be set (check .env)}"
: "${SUPABASE_OPERATOR_SERVICE_ROLE_KEY:?SUPABASE_OPERATOR_SERVICE_ROLE_KEY must be set (check .env)}"

export USE_SUPABASE_BACKEND=1

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/state.sh"

TEST_SLUG="test-state-m8"

cleanup() {
  local rc=$?
  echo "[cleanup] removing test rows..."
  # Cascade on customers will drop the runs row too; do customer-by-slug.
  curl --ssl-no-revoke -sS -X DELETE \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: operator_ui" \
    -H "Content-Profile: operator_ui" \
    "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}" \
    >/dev/null || true
  if [ $rc -eq 0 ]; then
    echo "[cleanup] done"
  fi
  exit $rc
}
trap cleanup EXIT

# Pre-clean any leftover row from a prior failed run.
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}" \
  >/dev/null || true

echo "[1/6] state_init $TEST_SLUG"
slug_with_ts="$(state_init "$TEST_SLUG")"
if [[ -z "$slug_with_ts" ]]; then
  echo "  [FAIL] state_init returned empty"; exit 1
fi
if [[ "$slug_with_ts" != "${TEST_SLUG}-"* ]]; then
  echo "  [FAIL] expected slug-with-ts to start with '${TEST_SLUG}-', got '$slug_with_ts'"; exit 1
fi
echo "  [PASS] init -> $slug_with_ts"

# state_init's export happens in a subshell when called via $(...). Re-export
# it so the rest of the script sees it (matches the legacy self-test pattern).
export STATE_RUN_DIR="$slug_with_ts"

echo "[2/6] state_set customer_name 'Test M8'"
state_set "customer_name" "Test M8"
echo "  [PASS] set returned 0"

echo "[3/6] state_get customer_name"
got="$(state_get "customer_name")"
if [[ "$got" != "Test M8" ]]; then
  echo "  [FAIL] expected 'Test M8', got '$got'"; exit 1
fi
echo "  [PASS] got '$got'"

echo "[4/6] state_stage_complete 3"
state_stage_complete 3 '{"info":"m8-test"}'
echo "  [PASS] stage_complete returned 0"

echo "[5/6] state_get_next_stage"
nxt="$(state_get_next_stage)"
if [[ "$nxt" != "4" ]]; then
  echo "  [FAIL] expected '4', got '$nxt'"; exit 1
fi
echo "  [PASS] next stage is 4"

echo "[6/6] state_resume_from $TEST_SLUG"
unset STATE_RUN_DIR
resumed="$(state_resume_from "$TEST_SLUG")"
if [[ "$resumed" != "$slug_with_ts" ]]; then
  echo "  [FAIL] expected '$slug_with_ts', got '$resumed'"; exit 1
fi
echo "  [PASS] resume_from matched"

echo ""
echo "All M8 assertions passed."
exit 0
