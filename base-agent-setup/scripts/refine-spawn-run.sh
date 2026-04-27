#!/usr/bin/env bash
# scripts/refine-spawn-run.sh <slug>
#
# Spawn a new run row for the customer's latest run, with refined_from_run_id
# pointing at the source. Copy every artifact from the source run into the
# new run as the baseline (the "before" the refine patches apply).
#
# M23 Fix 5 — atomic. The old version did two separate POSTs (runs INSERT,
# artifacts INSERT). If the script process died between them, the new run
# existed with zero artifacts. Now both inserts run inside a single SQL
# transaction via the operator_ui.spawn_refine_run() RPC defined in
# migrations/operator_ui_spawn_run.sql. PostgREST exposes it at
# /rpc/spawn_refine_run; we POST {source_run_id} and read back
# {slug_with_ts, id}.
#
# Stdout (unchanged contract): the new run's slug_with_ts and id,
# tab-separated, on one line:
#   <slug_with_ts>\t<run_uuid>
# So the orchestrator can capture both with a single `read`:
#   read -r NEW_SLUG_TS NEW_RUN_ID < <(bash scripts/refine-spawn-run.sh "$SLUG")
# State env exports are NOT done here because this is a one-shot helper.
#
# Halt-on-error: customer-not-found, no-runs, RPC failure → stderr + exit 1.

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

SRC_RUN_ID="$(supabase_get "runs?customer_id=eq.${CUSTOMER_ID}&order=created_at.desc&limit=1&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$SRC_RUN_ID" ]; then
  echo "refine-spawn-run: no runs for slug '$SLUG'" >&2
  exit 1
fi

# Call the atomic RPC. Body shape: {"source_run_id": "<uuid>"}.
RPC_BODY="$(python3 -c 'import json,sys; print(json.dumps({"source_run_id": sys.argv[1]}))' "$SRC_RUN_ID")"
RPC_RESP="$(supabase_post "rpc/spawn_refine_run" "$RPC_BODY")"

# PostgREST returns the function's `returns table` as either a JSON array of
# row objects or a single object — defensively accept both shapes.
PARSED="$(python3 -c '
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write(f"refine-spawn-run: RPC response not JSON: {raw[:200]}\n")
    sys.exit(1)
if isinstance(d, list):
    if not d:
        sys.stderr.write("refine-spawn-run: RPC returned empty array\n")
        sys.exit(1)
    row = d[0]
else:
    row = d
slug_ts = row.get("slug_with_ts")
rid = row.get("id")
if not slug_ts or not rid:
    sys.stderr.write(f"refine-spawn-run: RPC response missing fields: {raw[:200]}\n")
    sys.exit(1)
print(f"{slug_ts}\t{rid}")
' "$RPC_RESP")"

printf '%s\n' "$PARSED"
