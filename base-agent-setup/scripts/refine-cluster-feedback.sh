#!/usr/bin/env bash
# scripts/refine-cluster-feedback.sh <slug>
#
# Read open feedback rows for the customer with <slug> across ALL runs, group
# by (lower-cased artifact_name, comment-prefix-80). Emit clusters with size
# >= 2 as JSON Lines on stdout.
#
# Output schema (per line):
#   {"key": "<artifact>|<prefix80>", "artifact_name": "...",
#    "comment_prefix": "...", "size": N, "feedback_ids": ["F-..."],
#    "quotes": ["..."], "comments": ["..."]}
#
# Empty result → empty stdout, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: refine-cluster-feedback.sh <slug>" >&2
  exit 1
fi

CUSTOMER_ID="$(supabase_get "customers?slug=eq.${SLUG}&select=id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
if [ -z "$CUSTOMER_ID" ]; then
  echo "refine-cluster-feedback: no customer for slug '$SLUG'" >&2
  exit 1
fi

RESP="$(supabase_get "feedback?customer_id=eq.${CUSTOMER_ID}&status=eq.open&select=id,artifact_name,quote,comment&order=created_at.asc")"

python3 -c '
import json, sys
from collections import defaultdict

rows = json.loads(sys.argv[1] or "[]")
clusters = defaultdict(list)
for r in rows:
    art = (r.get("artifact_name") or "").strip().lower()
    com = (r.get("comment") or "").strip()
    prefix = com[:80].lower()
    key = f"{art}|{prefix}"
    clusters[key].append(r)

for key, items in clusters.items():
    if len(items) < 2:
        continue
    art = items[0].get("artifact_name") or ""
    com_prefix = (items[0].get("comment") or "")[:80]
    out = {
        "key": key,
        "artifact_name": art,
        "comment_prefix": com_prefix,
        "size": len(items),
        "feedback_ids": [i["id"] for i in items],
        "quotes": [i.get("quote", "") for i in items],
        "comments": [i.get("comment", "") for i in items],
    }
    print(json.dumps(out, ensure_ascii=False))
' "$RESP"
