#!/usr/bin/env bash
# scripts/log_deployment.sh
#
# Append a row to operator_ui.deployment_log capturing one external
# mutation made by /base-agent during onboarding. Every Stage that
# creates / tags / wires anything outside this run-dir should call this
# helper immediately after the mutation succeeds. The /base-agent remove
# skill replays these rows in reverse to tear the deployment down cleanly.
#
# Usage (named flags only — argv parsing is strict):
#   bash scripts/log_deployment.sh \
#     --slug acme-plumbing \
#     --run-id acme-plumbing-2026-04-28T10-00-00Z \
#     --stage 7 \
#     --system telnyx \
#     --action tagged \
#     --target-kind did \
#     --target-id 1234567890abcdef \
#     --payload '{"phone_number":"+61291374107","voice_url":"https://..."}' \
#     --inverse-op untag_repool \
#     --inverse-payload '{"number_id":"1234567890abcdef","old_tag":"claimed-acme-plumbing","new_tag":"pool-available","prior_voice_url":""}'
#
# Required: --slug, --stage, --system, --action, --target-kind, --target-id, --inverse-op
# Optional: --run-id, --payload, --inverse-payload
#
# Returns 0 on success. On failure prints to stderr and returns 1; the
# caller decides whether to halt the stage. Log writes should never
# silently swallow errors — a missing log entry means a future remove
# will rely on drift detection, which is less reliable.
#
# Sourced helpers: scripts/supabase.sh (operator_ui REST). Required env:
#   SUPABASE_OPERATOR_URL
#   SUPABASE_OPERATOR_SERVICE_ROLE_KEY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

# --- arg parsing ---------------------------------------------------------

SLUG=""
RUN_ID=""
STAGE=""
SYSTEM=""
ACTION=""
TARGET_KIND=""
TARGET_ID=""
PAYLOAD=""
INVERSE_OP=""
INVERSE_PAYLOAD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --target-kind) TARGET_KIND="$2"; shift 2 ;;
    --target-id) TARGET_ID="$2"; shift 2 ;;
    --payload) PAYLOAD="$2"; shift 2 ;;
    --inverse-op) INVERSE_OP="$2"; shift 2 ;;
    --inverse-payload) INVERSE_PAYLOAD="$2"; shift 2 ;;
    *)
      echo "log_deployment: unknown arg '$1'" >&2
      exit 1
      ;;
  esac
done

for var in SLUG STAGE SYSTEM ACTION TARGET_KIND TARGET_ID INVERSE_OP; do
  if [ -z "${!var}" ]; then
    echo "log_deployment: --${var,,} required" >&2
    exit 1
  fi
done

# --- validate JSON payloads ----------------------------------------------
# Empty string → null. Non-empty → must parse as JSON.

if [ -n "$PAYLOAD" ]; then
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$PAYLOAD" >/dev/null 2>&1 || {
    echo "log_deployment: --payload is not valid JSON" >&2
    exit 1
  }
fi
if [ -n "$INVERSE_PAYLOAD" ]; then
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$INVERSE_PAYLOAD" >/dev/null 2>&1 || {
    echo "log_deployment: --inverse-payload is not valid JSON" >&2
    exit 1
  }
fi

# --- build + POST -------------------------------------------------------

BODY="$(python3 - "$SLUG" "$RUN_ID" "$STAGE" "$SYSTEM" "$ACTION" \
                  "$TARGET_KIND" "$TARGET_ID" "$PAYLOAD" \
                  "$INVERSE_OP" "$INVERSE_PAYLOAD" <<'PY'
import json, sys
slug, run_id, stage, system, action, target_kind, target_id, \
    payload, inverse_op, inverse_payload = sys.argv[1:11]

row = {
    "customer_slug": slug,
    "stage": int(stage),
    "system": system,
    "action": action,
    "target_kind": target_kind,
    "target_id": target_id,
    "inverse_op": inverse_op,
    "status": "active",
}
if run_id:
    row["run_id_text"] = run_id
if payload:
    row["payload"] = json.loads(payload)
if inverse_payload:
    row["inverse_payload"] = json.loads(inverse_payload)

print(json.dumps(row))
PY
)"

RESP="$(supabase_post "deployment_log" "$BODY")"

# Validate the response shape (should be a 1-element array with an id).
# Pipe via stdin so embedded quotes/newlines in the response don't break
# the heredoc.
printf '%s' "$RESP" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(f"log_deployment: non-JSON response from Supabase: {raw[:200]}", file=sys.stderr)
    sys.exit(1)
if not isinstance(d, list) or len(d) != 1 or "id" not in d[0]:
    print(f"log_deployment: unexpected response: {d}", file=sys.stderr)
    sys.exit(1)
'
