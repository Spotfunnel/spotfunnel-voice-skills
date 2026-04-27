#!/usr/bin/env bash
# scripts/regenerate-agent.sh <slug>
#
# Push the latest system-prompt artifact to a live Ultravox agent via a
# safe full-PATCH that preserves voice/temperature/inactivity/tools/etc.
#
# The flow:
#   1. Locate the customer's most recent run via state_resume_from <slug>.
#   2. Read state.ultravox_agent_id (Stage 6 wrote it).
#   3. Read the latest system-prompt artifact from operator_ui.artifacts.
#   4. Hand off to _ultravox_safe_patch.py for the three Ultravox HTTP calls
#      (GET → PATCH full body → GET-back → diff).
#   5. On success, persist the pre-update snapshot to state.live_agent_pre_update
#      and stamp state.system_prompt_pushed_at = ISO now.
#
# Halt-on-error throughout. Non-zero exit = stop. The orchestrator (SKILL.md
# Step 9 of /base-agent refine) interprets a non-zero exit as "do not advance".
#
# Requires:
#   USE_SUPABASE_BACKEND=1
#   SUPABASE_OPERATOR_URL + SUPABASE_OPERATOR_SERVICE_ROLE_KEY
#   ULTRAVOX_API_KEY
# Optional:
#   ULTRAVOX_BASE_URL — override for tests; defaults to https://api.ultravox.ai

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: regenerate-agent.sh <slug>" >&2
  exit 1
fi

if [ "${USE_SUPABASE_BACKEND:-0}" != "1" ]; then
  echo "regenerate-agent: requires USE_SUPABASE_BACKEND=1 (legacy file backend has no Supabase agent_id lookup)" >&2
  exit 1
fi

if [ -z "${ULTRAVOX_API_KEY:-}" ]; then
  echo "regenerate-agent: ULTRAVOX_API_KEY is empty — set it in .env" >&2
  exit 1
fi

# 1. Locate the latest run for this slug.
SLUG_WITH_TS="$(state_resume_from "$SLUG")"

# 2. Read state.ultravox_agent_id from operator_ui.runs.state for that run.
AGENT_ID="$(supabase_get "runs?slug_with_ts=eq.${SLUG_WITH_TS}&select=state" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
state = (d[0]["state"] if d else {}) or {}
print(state.get("ultravox_agent_id", ""))
')"
if [ -z "$AGENT_ID" ]; then
  echo "regenerate-agent: no ultravox_agent_id in state for run ${SLUG_WITH_TS}" >&2
  exit 1
fi

# 3. Read the latest system-prompt artifact for that run.
RUN_ID="$(supabase_get "runs?slug_with_ts=eq.${SLUG_WITH_TS}&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$RUN_ID" ]; then
  echo "regenerate-agent: failed to resolve run id for ${SLUG_WITH_TS}" >&2
  exit 1
fi

PROMPT_TMP="$(mktemp)"
SNAPSHOT_TMP="$(mktemp)"
trap 'rm -f "$PROMPT_TMP" "$SNAPSHOT_TMP"' EXIT

supabase_get "artifacts?run_id=eq.${RUN_ID}&artifact_name=eq.system-prompt&select=content" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d:
    sys.stderr.write("regenerate-agent: no system-prompt artifact for this run\n")
    sys.exit(1)
sys.stdout.write(d[0]["content"])
' > "$PROMPT_TMP"

if [ ! -s "$PROMPT_TMP" ]; then
  echo "regenerate-agent: system-prompt artifact is empty" >&2
  exit 1
fi

# 4. Hand off to the Python helper for the three Ultravox HTTP calls.
echo "[INFO] regenerate-agent: PATCHing Ultravox agent ${AGENT_ID} for slug=${SLUG}"

set +e
python3 "$SCRIPT_DIR/_ultravox_safe_patch.py" \
  --agent-id "$AGENT_ID" \
  --new-prompt-file "$PROMPT_TMP" \
  --pre-snapshot-out "$SNAPSHOT_TMP"
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "[ERR] regenerate-agent: safe-patch helper exited $RC" >&2
  exit $RC
fi

# 5. Persist the pre-update snapshot + pushed_at into state.
SNAPSHOT_JSON="$(cat "$SNAPSHOT_TMP")"
ISO_NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

CURRENT="$(supabase_get "runs?slug_with_ts=eq.${SLUG_WITH_TS}&select=state" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]["state"]) if d else "{}")')"

NEW_STATE="$(python3 -c '
import json, sys
state = json.loads(sys.argv[1])
state["live_agent_pre_update"] = json.loads(sys.argv[2])
state["system_prompt_pushed_at"] = sys.argv[3]
print(json.dumps(state))
' "$CURRENT" "$SNAPSHOT_JSON" "$ISO_NOW")"

BODY="$(python3 -c 'import json,sys; print(json.dumps({"state": json.loads(sys.argv[1])}))' "$NEW_STATE")"
supabase_patch "runs?slug_with_ts=eq.${SLUG_WITH_TS}" "$BODY" >/dev/null

echo "[OK] regenerate-agent: agent ${AGENT_ID} updated; pre-update snapshot saved to state.live_agent_pre_update; pushed_at=${ISO_NOW}"
exit 0
