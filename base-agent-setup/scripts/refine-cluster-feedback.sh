#!/usr/bin/env bash
# scripts/refine-cluster-feedback.sh <slug>
# scripts/refine-cluster-feedback.sh --all-customers
#
# Read open feedback rows and group by (lower-cased artifact_name,
# comment-prefix-80). Emit clusters with size >= 2 as JSON Lines on stdout.
#
# Two modes:
#   - <slug>: scope to one customer (M12 refine flow).
#   - --all-customers: cross-customer scope (M14 review-feedback flow).
#
# Output schema (per line):
#   {"key": "<artifact>|<prefix80>", "artifact_name": "...",
#    "comment_prefix": "...", "size": N, "feedback_ids": ["F-..."],
#    "quotes": ["..."], "comments": ["..."], "customer_ids": ["uuid", ...]}
#
# Empty result → empty stdout, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

ARG="${1:-}"
if [ -z "$ARG" ]; then
  echo "Usage: refine-cluster-feedback.sh <slug> | --all-customers" >&2
  exit 1
fi

if [ "$ARG" = "--all-customers" ]; then
  RESP="$(supabase_get "feedback?status=eq.open&select=id,customer_id,artifact_name,quote,comment&order=created_at.asc")"
else
  SLUG="$ARG"
  CUSTOMER_ID="$(supabase_get "customers?slug=eq.${SLUG}&select=id" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  if [ -z "$CUSTOMER_ID" ]; then
    echo "refine-cluster-feedback: no customer for slug '$SLUG'" >&2
    exit 1
  fi
  RESP="$(supabase_get "feedback?customer_id=eq.${CUSTOMER_ID}&status=eq.open&select=id,customer_id,artifact_name,quote,comment&order=created_at.asc")"
fi

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
    cust_ids = []
    for i in items:
        cid = i.get("customer_id")
        if cid and cid not in cust_ids:
            cust_ids.append(cid)
    out = {
        "key": key,
        "artifact_name": art,
        "comment_prefix": com_prefix,
        "size": len(items),
        "feedback_ids": [i["id"] for i in items],
        "quotes": [i.get("quote", "") for i in items],
        "comments": [i.get("comment", "") for i in items],
        "customer_ids": cust_ids,
    }
    print(json.dumps(out, ensure_ascii=False))
' "$RESP"
