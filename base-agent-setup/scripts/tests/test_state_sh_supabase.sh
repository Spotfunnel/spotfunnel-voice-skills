#!/usr/bin/env bash
# scripts/tests/test_state_sh_supabase.sh
#
# Deep stress test for state.sh under USE_SUPABASE_BACKEND=1.
# Validates the post-C1 contract:
#   STATE_RUN_DIR  = filesystem scratch path (runs/{slug_with_ts}/)
#   STATE_RUN_ID   = slug_with_ts (used by all DB lookups)
#
# Tests the SOURCED-library use case — state_init / state_set / state_get
# called in the same shell, without any caller-side re-export. That mirrors
# how SKILL.md actually drives state.sh during a real /base-agent run.
#
# Distinct from test_state_sh.sh (which is the legacy file-backend smoke
# test); this one exercises the Supabase branch and the dual contract.
#
# Usage:
#   cd base-agent-setup/scripts/tests && bash test_state_sh_supabase.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ] && [ -z "${SUPABASE_OPERATOR_URL:-}" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +o allexport
fi

: "${SUPABASE_OPERATOR_URL:?must be set (check .env)}"
: "${SUPABASE_OPERATOR_SERVICE_ROLE_KEY:?must be set (check .env)}"

export USE_SUPABASE_BACKEND=1

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/state.sh"

TEST_SLUG="test-stress-supabase-$$"

cleanup() {
  local rc=$?
  echo "[cleanup] removing test rows + scratch dir..."
  curl --ssl-no-revoke -sS -X DELETE \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: operator_ui" \
    -H "Content-Profile: operator_ui" \
    "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}" \
    >/dev/null || true
  [ -n "${STATE_RUN_DIR:-}" ] && [ -d "$STATE_RUN_DIR" ] && rm -rf "$STATE_RUN_DIR" || true
  exit $rc
}
trap cleanup EXIT

# -- pre-clean --
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}" \
  >/dev/null || true

fail() {
  echo "  [FAIL] $1"
  exit 1
}
pass() {
  echo "  [PASS] $1"
}

echo "[1] state_init exports BOTH STATE_RUN_DIR (path) and STATE_RUN_ID (slug_with_ts)"
# Source-style call: function exports propagate to current shell.
slug_with_ts="$(state_init "$TEST_SLUG")"
# state_init was called via $(...) — exports happen in subshell. Re-source-call
# differently: invoke directly so exports stick.
unset STATE_RUN_DIR STATE_RUN_ID
# Re-invoke without command substitution so the exports stick.
state_init "$TEST_SLUG-direct" >/dev/null
[ -n "${STATE_RUN_DIR:-}" ] || fail "STATE_RUN_DIR not exported"
[ -n "${STATE_RUN_ID:-}" ] || fail "STATE_RUN_ID not exported"
[ -d "$STATE_RUN_DIR" ] || fail "STATE_RUN_DIR is not a directory: $STATE_RUN_DIR"
[[ "$STATE_RUN_ID" == "${TEST_SLUG}-direct-"* ]] || fail "STATE_RUN_ID malformed: $STATE_RUN_ID"
[[ "$STATE_RUN_DIR" == */runs/${STATE_RUN_ID} ]] || fail "STATE_RUN_DIR doesn't end in runs/\$STATE_RUN_ID: $STATE_RUN_DIR"
TEST_SLUG_DIRECT="$TEST_SLUG-direct"
pass "STATE_RUN_DIR=$STATE_RUN_DIR"
pass "STATE_RUN_ID=$STATE_RUN_ID"

echo "[2] state_set + state_get round-trip without caller re-export"
# This is the contract that test_state_sh.sh's manual STATE_RUN_DIR override
# was hiding. If _state_supabase_run_id() reads STATE_RUN_DIR (path) instead of
# STATE_RUN_ID (slug), this set/get will silently no-op or write to the wrong
# row. Use a value that's unique so a stale row can't fake a pass.
NONCE="nonce-$RANDOM-$RANDOM"
state_set "marker" "$NONCE"
got="$(state_get "marker")"
[ "$got" = "$NONCE" ] || fail "round-trip failed: set='$NONCE' get='$got'"
pass "set/get round-trip ok ($NONCE)"

echo "[3] state_get for missing key returns empty"
empty="$(state_get "no-such-key-$RANDOM")"
[ -z "$empty" ] || fail "missing key should be empty, got '$empty'"
pass "missing key → empty"

echo "[4] state_stage_complete + state_get_next_stage"
state_stage_complete 2 '{"pages":42}'
state_stage_complete 5 '{"agent_id":"abc"}'
nxt="$(state_get_next_stage)"
[ "$nxt" = "6" ] || fail "expected next=6 (max(2,5)+1), got '$nxt'"
pass "stage_complete advances correctly"

echo "[5] state_stage_complete with malformed JSON rejected"
if state_stage_complete 7 'not-json' 2>/dev/null; then
  fail "expected non-zero exit on malformed JSON outputs"
fi
pass "malformed JSON rejected"

echo "[6] state_resume_from a fresh shell (simulated by unsetting + resourcing)"
PRIOR_RUN_ID="$STATE_RUN_ID"
PRIOR_RUN_DIR="$STATE_RUN_DIR"
unset STATE_RUN_DIR STATE_RUN_ID
state_resume_from "$TEST_SLUG_DIRECT" >/dev/null
[ "$STATE_RUN_ID" = "$PRIOR_RUN_ID" ] || fail "resume STATE_RUN_ID mismatch: '$STATE_RUN_ID' vs '$PRIOR_RUN_ID'"
[ "$STATE_RUN_DIR" = "$PRIOR_RUN_DIR" ] || fail "resume STATE_RUN_DIR mismatch: '$STATE_RUN_DIR' vs '$PRIOR_RUN_DIR'"
[ -d "$STATE_RUN_DIR" ] || fail "resume should ensure STATE_RUN_DIR exists"
pass "resume_from re-exports both vars correctly"

echo "[7] state_get after resume reads same row (no shadow row)"
got_after_resume="$(state_get "marker")"
[ "$got_after_resume" = "$NONCE" ] || fail "post-resume read mismatch: '$got_after_resume' vs '$NONCE'"
pass "post-resume read sees prior writes"

echo "[8] resume_from on bogus slug returns non-zero"
if state_resume_from "no-customer-$RANDOM-$$" >/dev/null 2>&1; then
  fail "should fail for non-existent slug"
fi
pass "bogus slug → non-zero"

echo "[9] state_set returns 1 when STATE_RUN_DIR/ID is unset"
unset STATE_RUN_DIR STATE_RUN_ID
if state_set "key" "v" 2>/dev/null; then
  fail "state_set should refuse with no run context"
fi
pass "no-context state_set refused"

echo "[10] cleanup of TEST_SLUG row from step 1 (the command-substitution call)"
# That call leaked a customer row because STATE_RUN_DIR was lost in the subshell.
# Cleanup happens via trap.
echo ""
echo "All 10 stress-test assertions passed."
exit 0
