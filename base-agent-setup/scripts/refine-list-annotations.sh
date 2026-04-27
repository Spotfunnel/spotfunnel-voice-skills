#!/usr/bin/env bash
# scripts/refine-list-annotations.sh <slug>
#
# Print open annotations for the most-recent run of <slug> as JSON Lines.
# One annotation per line; the orchestrator walks them in order.
#
# Output schema (per line):
#   {"id": "...", "run_id": "...", "artifact_name": "...",
#    "char_start": N, "char_end": M, "quote": "...", "comment": "...",
#    "author_name": "...", "created_at": "..."}
#
# Halt-on-error: customer-not-found / no-runs / non-200 → stderr + exit 1.
# Zero open annotations → empty stdout, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: refine-list-annotations.sh <slug>" >&2
  exit 1
fi

CUSTOMER_ID="$(supabase_get "customers?slug=eq.${SLUG}&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$CUSTOMER_ID" ]; then
  echo "refine-list-annotations: no customer for slug '$SLUG'" >&2
  exit 1
fi

RUN_ID="$(supabase_get "runs?customer_id=eq.${CUSTOMER_ID}&order=created_at.desc&limit=1&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$RUN_ID" ]; then
  echo "refine-list-annotations: no runs for slug '$SLUG'" >&2
  exit 1
fi

# Fetch open annotations ordered by (artifact_name, char_start). PostgREST
# multi-column ordering uses comma-separated `order=`.
RESP="$(supabase_get "annotations?run_id=eq.${RUN_ID}&status=eq.open&order=artifact_name.asc,char_start.asc&select=id,run_id,artifact_name,char_start,char_end,quote,comment,author_name,created_at")"

python3 -c '
import json, sys
rows = json.loads(sys.argv[1] or "[]")
for r in rows:
    print(json.dumps(r, ensure_ascii=False))
' "$RESP"
