#!/usr/bin/env bash
# scripts/refine-spawn-run.sh <slug>
#
# Spawn a new run row for the customer's latest run, with refined_from_run_id
# pointing at the source. Copy every artifact from the source run into the
# new run as the baseline (the "before" the refine patches apply).
#
# Stdout: the new run's slug_with_ts and id, tab-separated, on one line:
#   <slug_with_ts>\t<run_uuid>
# So the orchestrator can capture both with a single `read`:
#   read -r NEW_SLUG_TS NEW_RUN_ID < <(bash scripts/refine-spawn-run.sh "$SLUG")
# State env exports are NOT done here because this is a one-shot helper.
#
# Halt-on-error: customer-not-found, no-runs, insert-failure → stderr + exit 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: refine-spawn-run.sh <slug>" >&2
  exit 1
fi

CUSTOMER_ID="$(supabase_get "customers?slug=eq.${SLUG}&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$CUSTOMER_ID" ]; then
  echo "refine-spawn-run: no customer for slug '$SLUG'" >&2
  exit 1
fi

SRC="$(supabase_get "runs?customer_id=eq.${CUSTOMER_ID}&order=created_at.desc&limit=1&select=id,slug_with_ts,state" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else "")')"
if [ -z "$SRC" ]; then
  echo "refine-spawn-run: no runs for slug '$SLUG'" >&2
  exit 1
fi

SRC_RUN_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$SRC")"
SRC_STATE="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["state"] or {}))' "$SRC")"

TS="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ"))')"
ISO_NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
NEW_SLUG_TS="${SLUG}-refine-${TS}"

# Fresh state with refine provenance noted (state.refined_from_slug_with_ts).
NEW_STATE="$(python3 -c '
import json, sys
state = json.loads(sys.argv[1])
state["refined_from_slug_with_ts"] = sys.argv[2]
print(json.dumps(state))
' "$SRC_STATE" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slug_with_ts"])' "$SRC")")"

INSERT_BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "customer_id": sys.argv[1],
    "slug_with_ts": sys.argv[2],
    "started_at": sys.argv[3],
    "state": json.loads(sys.argv[4]),
    "refined_from_run_id": sys.argv[5],
}))
' "$CUSTOMER_ID" "$NEW_SLUG_TS" "$ISO_NOW" "$NEW_STATE" "$SRC_RUN_ID")"

NEW_RUN="$(supabase_post "runs" "$INSERT_BODY")"
NEW_RUN_ID="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not isinstance(d, list) or not d or "id" not in d[0]:
    sys.stderr.write(f"refine-spawn-run: insert failed: {sys.argv[1]}\n")
    sys.exit(1)
print(d[0]["id"])
' "$NEW_RUN")"

# Copy every artifact from the source run into the new run.
ARTIFACTS="$(supabase_get "artifacts?run_id=eq.${SRC_RUN_ID}&select=artifact_name,content,size_bytes")"
python3 -c '
import json, sys
rows = json.loads(sys.argv[1] or "[]")
print(json.dumps([
    {"run_id": sys.argv[2], "artifact_name": r["artifact_name"],
     "content": r["content"], "size_bytes": r["size_bytes"]}
    for r in rows
]))
' "$ARTIFACTS" "$NEW_RUN_ID" > /tmp/.refine-artifacts-$$.json

# Bulk insert if any artifacts to carry over. Empty list is fine; skip the POST.
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' /tmp/.refine-artifacts-$$.json)"
if [ "$COUNT" -gt 0 ]; then
  BODY="$(cat /tmp/.refine-artifacts-$$.json)"
  curl --ssl-no-revoke -sS -X POST \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "$BODY" \
    "$SUPABASE_OPERATOR_URL/rest/v1/artifacts" \
    >/dev/null
fi
rm -f /tmp/.refine-artifacts-$$.json

printf '%s\t%s\n' "$NEW_SLUG_TS" "$NEW_RUN_ID"
