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

echo "[1a] state_init via direct call exports STATE_RUN_DIR + STATE_RUN_ID"
state_init "$TEST_SLUG-direct" >/dev/null
[ -n "${STATE_RUN_DIR:-}" ] || fail "STATE_RUN_DIR not exported"
[ -n "${STATE_RUN_ID:-}" ] || fail "STATE_RUN_ID not exported"
[ -d "$STATE_RUN_DIR" ] || fail "STATE_RUN_DIR is not a directory: $STATE_RUN_DIR"
[[ "$STATE_RUN_ID" == "${TEST_SLUG}-direct-"* ]] || fail "STATE_RUN_ID malformed: $STATE_RUN_ID"
[[ "$STATE_RUN_DIR" == */runs/${STATE_RUN_ID} ]] || fail "STATE_RUN_DIR doesn't end in runs/\$STATE_RUN_ID"
TEST_SLUG_DIRECT="$TEST_SLUG-direct"
pass "direct: STATE_RUN_DIR=$STATE_RUN_DIR"
pass "direct: STATE_RUN_ID=$STATE_RUN_ID"

echo "[1b] state_init via \$() echoes the run-dir path (matching legacy contract)"
# Exports lost in subshell, but the echoed value is the path — SKILL.md does
# RUN_DIR=$(state_init); export STATE_RUN_DIR="$RUN_DIR" and that must produce
# a working path under both backends.
unset STATE_RUN_DIR STATE_RUN_ID
echoed="$(state_init "$TEST_SLUG-captured")"
[[ "$echoed" == */runs/${TEST_SLUG}-captured-* ]] || fail "state_init should echo a runs/ path; got '$echoed'"
[ -d "$echoed" ] || fail "echoed path doesn't exist: $echoed"
TEST_SLUG_CAPTURED="$TEST_SLUG-captured"
# Simulate SKILL.md's pattern: capture via $(), then export STATE_RUN_DIR.
export STATE_RUN_DIR="$echoed"
pass "captured: STATE_RUN_DIR=$STATE_RUN_DIR"

echo "[1c] state_set works under SKILL.md's \$() capture pattern (no STATE_RUN_ID)"
# This is the path SKILL.md actually uses. Without basename fallback, the DB
# call would silently no-op against a missing slug.
state_set "captured_marker" "captured-$RANDOM"
got="$(state_get "captured_marker")"
[[ "$got" == captured-* ]] || fail "captured-pattern set/get failed: '$got'"
pass "captured-pattern set/get round-trips"

# Switch back to the direct-call run for the rest of the suite.
unset STATE_RUN_DIR STATE_RUN_ID
state_init "$TEST_SLUG-direct2" >/dev/null
TEST_SLUG_DIRECT="$TEST_SLUG-direct2"

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

echo "[10] state_set_artifact round-trips file content via Supabase"
# Re-init a fresh run (step 9 unset our context).
state_init "$TEST_SLUG-art" >/dev/null
ARTIFACT_FIXTURE="$STATE_RUN_DIR/brain-doc.md"
# Build body via Python so line endings are LF on every platform — the test
# script itself may be checked out with CRLF on Windows, which would corrupt
# a heredoc-style assignment.
python3 - "$ARTIFACT_FIXTURE" <<'PY'
import sys
body = (
    "# Brain Doc\n"
    "\n"
    "This is content with an embedded \"quote\" + apostrophe's + multi-line.\n"
    "\n"
    "- bullet\n"
    "- bullet two\n"
    "\n"
    "End."
)
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write(body)
PY
ARTIFACT_BODY="$(python3 - "$ARTIFACT_FIXTURE" <<'PY'
import sys
with open(sys.argv[1], "r", encoding="utf-8", newline="") as f:
    print(f.read(), end="")
PY
)"
state_set_artifact "brain-doc" "$ARTIFACT_FIXTURE" || fail "state_set_artifact returned non-zero"

# Verify via service-role GET that the artifact was upserted. Two-hop:
# resolve run_id from slug_with_ts, then read artifacts row.
slug_with_ts="$STATE_RUN_ID"
RUN_DB_ID="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/runs?slug_with_ts=eq.${slug_with_ts}&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
[ -n "$RUN_DB_ID" ] || fail "couldn't resolve run_id for $slug_with_ts"

ART_ROW="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/artifacts?run_id=eq.${RUN_DB_ID}&artifact_name=eq.brain-doc&select=content,size_bytes")"
got_content="$(echo "$ART_ROW" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["content"] if d else "")')"
got_size="$(echo "$ART_ROW" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["size_bytes"] if d else "")')"

if [ "$got_content" != "$ARTIFACT_BODY" ]; then
  echo "  expected: $(printf '%s' "$ARTIFACT_BODY" | xxd | head -5)"
  echo "  got:      $(printf '%s' "$got_content" | xxd | head -5)"
  fail "content roundtrip mismatch"
fi
EXPECTED_SIZE="$(wc -c < "$ARTIFACT_FIXTURE" | tr -d ' ')"
[ "$got_size" = "$EXPECTED_SIZE" ] || fail "size_bytes mismatch: db=$got_size local=$EXPECTED_SIZE"
pass "state_set_artifact round-trip ok ($got_size bytes)"

echo "[11] state_set_artifact is idempotent (upsert on conflict)"
NEW_BODY="updated $RANDOM"
python3 - "$ARTIFACT_FIXTURE" "$NEW_BODY" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write(sys.argv[2])
PY
state_set_artifact "brain-doc" "$ARTIFACT_FIXTURE" || fail "second upsert failed"
ART_ROWS="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/artifacts?run_id=eq.${RUN_DB_ID}&artifact_name=eq.brain-doc&select=content")"
ROW_COUNT="$(echo "$ART_ROWS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$ROW_COUNT" = "1" ] || fail "expected 1 row after re-upsert, got $ROW_COUNT"
NEW_GOT="$(echo "$ART_ROWS" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["content"])')"
[ "$NEW_GOT" = "$NEW_BODY" ] || fail "upsert didn't replace content: '$NEW_GOT' vs '$NEW_BODY'"
pass "upsert kept row count at 1, replaced content"

echo "[12] state_set_artifact in legacy mode is a no-op (USE_SUPABASE_BACKEND=0)"
# Stash + restore the flag so the rest of the suite isn't affected.
prev="${USE_SUPABASE_BACKEND:-}"
USE_SUPABASE_BACKEND=0
state_set_artifact "should-not-create" "$ARTIFACT_FIXTURE" || fail "legacy no-op shouldn't return non-zero"
USE_SUPABASE_BACKEND="$prev"
pass "legacy no-op ok"

echo "[13] state_set_artifact rejects missing file"
if state_set_artifact "missing" "/no/such/path-$$" 2>/dev/null; then
  fail "should reject missing file"
fi
pass "missing-file rejected"

# Cleanup the test-art customer too (cascades to runs + artifacts).
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}-art" \
  >/dev/null || true
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG_CAPTURED}" \
  >/dev/null || true
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}-direct" \
  >/dev/null || true
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${TEST_SLUG}-direct2" \
  >/dev/null || true

echo ""
echo "All M9 stress-test assertions passed."
exit 0
