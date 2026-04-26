#!/usr/bin/env bash
# scripts/tests/test_m9_integration.sh
#
# M9 integration smoke test — simulates the artifact-producing slice of
# /base-agent end-to-end and verifies every artifact appears in the
# operator UI's data model.
#
# Stops short of consuming Ultravox/Telnyx resources — those stages are
# orthogonal to M9 (artifact mirroring) and add cost without strengthening
# the M9 contract. The integration covers exactly what M9 promises:
#
#   state_init -> 6 artifacts written + state_set_artifact + state_stage_complete
#   -> operator_ui.{customers,runs,artifacts} populated correctly
#
# This is the kind of thing a real /base-agent run produces by Stage 10;
# Stages 5-9 (telephony) just write strings to runs.state, which M8 already
# covers in test_state_sh_supabase.sh.
#
# Usage:
#   cd base-agent-setup/scripts/tests && bash test_m9_integration.sh

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

: "${SUPABASE_OPERATOR_URL:?must be set}"
: "${SUPABASE_OPERATOR_SERVICE_ROLE_KEY:?must be set}"

export USE_SUPABASE_BACKEND=1
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/state.sh"

INT_SLUG="m9-integration-$$"

cleanup() {
  local rc=$?
  echo "[cleanup] removing customer $INT_SLUG (cascades runs+artifacts)..."
  curl --ssl-no-revoke -sS -X DELETE \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: operator_ui" \
    -H "Content-Profile: operator_ui" \
    "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${INT_SLUG}" \
    >/dev/null || true
  [ -n "${STATE_RUN_DIR:-}" ] && [ -d "$STATE_RUN_DIR" ] && rm -rf "$STATE_RUN_DIR" || true
  exit $rc
}
trap cleanup EXIT

# Pre-clean
curl --ssl-no-revoke -sS -X DELETE \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  -H "Content-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${INT_SLUG}" \
  >/dev/null || true

fail() { echo "  [FAIL] $1"; exit 1; }
pass() { echo "  [PASS] $1"; }

# -----------------------------------------------------------------------
echo "[1] state_init creates customer + run rows"
RUN_DIR="$(state_init "$INT_SLUG")"
export STATE_RUN_DIR="$RUN_DIR"
[ -d "$STATE_RUN_DIR" ] || fail "STATE_RUN_DIR not created"
SLUG_WITH_TS="$(basename "$STATE_RUN_DIR")"
pass "init -> $SLUG_WITH_TS"

# -----------------------------------------------------------------------
echo "[2] Stage 1 — write meeting-transcript artifact"
python3 - "$STATE_RUN_DIR/meeting-transcript.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("# Meeting transcript\n\nLeo: Hi.\nProspect: Hi back.\n")
PY
state_set meeting_transcript_path "$STATE_RUN_DIR/meeting-transcript.md"
state_set_artifact meeting-transcript "$STATE_RUN_DIR/meeting-transcript.md"
state_stage_complete 1 '{"slug":"'"$INT_SLUG"'"}'
pass "stage 1 done"

# -----------------------------------------------------------------------
echo "[3] Stage 2 — write scrape combined.md artifact"
mkdir -p "$STATE_RUN_DIR/scrape"
python3 - "$STATE_RUN_DIR/scrape/combined.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("<!-- source: https://example.com -->\n# Example\n\nWelcome.\n---\n<!-- source: https://example.com/about -->\n# About\n")
PY
state_set_artifact scraped-pages "$STATE_RUN_DIR/scrape/combined.md"
state_stage_complete 2 '{"pages":2}'
pass "stage 2 done"

# -----------------------------------------------------------------------
echo "[4] Stage 3 — write brain-doc artifact"
python3 - "$STATE_RUN_DIR/brain-doc.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("# Brain doc\n\n## Business\nFixture content for M9 integration.\n")
PY
state_set_artifact brain-doc "$STATE_RUN_DIR/brain-doc.md"
state_stage_complete 3 '{"size_bytes":'"$(wc -c < "$STATE_RUN_DIR/brain-doc.md" | tr -d ' ')"'}'
pass "stage 3 done"

# -----------------------------------------------------------------------
echo "[5] Stage 4 — write system-prompt artifact"
python3 - "$STATE_RUN_DIR/system-prompt.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("=== AGENT_IDENTITY ===\nYou are an agent.\n=== /AGENT_IDENTITY ===\n")
PY
state_set_artifact system-prompt "$STATE_RUN_DIR/system-prompt.md"
state_stage_complete 4 '{"size_bytes":'"$(wc -c < "$STATE_RUN_DIR/system-prompt.md" | tr -d ' ')"'}'
pass "stage 4 done"

# -----------------------------------------------------------------------
echo "[6] Stage 10 — write discovery-prompt + customer-context + cover-email"
python3 - "$STATE_RUN_DIR/discovery-prompt.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("# Discovery prompt\n\nPaste this into ChatGPT...\n")
PY
python3 - "$STATE_RUN_DIR/customer-context.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("# Customer context\n\n# Business summary\nFixture\n# Meeting transcript\n...\n")
PY
python3 - "$STATE_RUN_DIR/cover-email.md" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    f.write("Subject: discovery\n\nHi,\n\nPlease paste this into ChatGPT.\n")
PY
state_set_artifact discovery-prompt "$STATE_RUN_DIR/discovery-prompt.md"
state_set_artifact cover-email "$STATE_RUN_DIR/cover-email.md"
[ -f "$STATE_RUN_DIR/customer-context.md" ] && state_set_artifact customer-context "$STATE_RUN_DIR/customer-context.md"
state_stage_complete 10 '{"size_path":"two-file","discovery_chars":42}'
pass "stage 10 done"

# -----------------------------------------------------------------------
echo "[7] Verify operator_ui.customers has the row"
CUST_ROW="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/customers?slug=eq.${INT_SLUG}&select=id,slug")"
HAS_CUST="$(echo "$CUST_ROW" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$HAS_CUST" = "1" ] || fail "customers row missing for $INT_SLUG"
pass "customer row found"

# -----------------------------------------------------------------------
echo "[8] Verify operator_ui.runs has the row with correct stage_complete=10"
RUN_ROW="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/runs?slug_with_ts=eq.${SLUG_WITH_TS}&select=id,stage_complete,state")"
RUN_DB_ID="$(echo "$RUN_ROW" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
STAGE="$(echo "$RUN_ROW" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["stage_complete"])')"
[ "$STAGE" = "10" ] || fail "expected stage_complete=10, got $STAGE"
pass "run row at stage 10"

# -----------------------------------------------------------------------
echo "[9] Verify all 6 artifacts persisted in operator_ui.artifacts"
EXPECTED_NAMES=("meeting-transcript" "scraped-pages" "brain-doc" "system-prompt" "discovery-prompt" "cover-email" "customer-context")
ARTS="$(curl --ssl-no-revoke -sS \
  -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
  -H "Accept-Profile: operator_ui" \
  "$SUPABASE_OPERATOR_URL/rest/v1/artifacts?run_id=eq.${RUN_DB_ID}&select=artifact_name,size_bytes")"
GOT_NAMES="$(echo "$ARTS" | python3 -c 'import json,sys; print(",".join(sorted(a["artifact_name"] for a in json.load(sys.stdin))))')"
EXPECTED="$(printf '%s\n' "${EXPECTED_NAMES[@]}" | sort | paste -sd ',' -)"
if [ "$GOT_NAMES" != "$EXPECTED" ]; then
  fail "artifact set mismatch — got [$GOT_NAMES] expected [$EXPECTED]"
fi
pass "all 7 artifacts present (6 always + customer-context for two-file path)"

# -----------------------------------------------------------------------
echo "[10] Verify each artifact's size_bytes is positive"
ALL_POS="$(echo "$ARTS" | python3 -c '
import json, sys
data = json.load(sys.stdin)
bad = [a["artifact_name"] for a in data if a["size_bytes"] <= 0]
print("ok:" + str(len(data)) if not bad else "bad:" + ",".join(bad))
')"
case "$ALL_POS" in
  ok:*) pass "all ${ALL_POS#ok:} size_bytes are positive" ;;
  *) fail "non-positive size_bytes on: ${ALL_POS#bad:}" ;;
esac

echo ""
echo "M9 integration: customer + run + 7 artifacts written end-to-end via state.sh."
echo "Operator UI at zero-onboarding.vercel.app should now list this customer until cleanup runs."
echo "(cleanup runs at trap EXIT — for visual verification, run with: bash test_m9_integration.sh && sleep 60)"
exit 0
