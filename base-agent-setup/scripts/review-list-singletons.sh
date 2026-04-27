#!/usr/bin/env bash
# scripts/review-list-singletons.sh
#
# Open feedback rows that DON'T form a cluster of size >= 2. Same heuristic
# as refine-cluster-feedback.sh: group by (lower(artifact_name),
# comment[:80].lower()). Emit each singleton as one JSONL line.
#
# Output schema (per line):
#   {"feedback_id": "F-...", "customer_id": "uuid", "artifact_name": "...",
#    "quote": "...", "comment": "..."}
#
# Empty result → empty stdout, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

RESP="$(supabase_get "feedback?status=eq.open&select=id,customer_id,artifact_name,quote,comment&order=created_at.asc")"

# Stage RESP to a temp file — Windows ARG_MAX (~32K) gets hit fast once the
# feedback table has accumulated rows across many customers.
TMP_BASE="${TMPDIR:-$HOME/.tmp-spotfunnel-skills}"
mkdir -p "$TMP_BASE"
RESP_TMP="$(mktemp -p "$TMP_BASE" list-singletons.XXXXXX)"
trap 'rm -f "$RESP_TMP"' EXIT
printf '%s' "$RESP" > "$RESP_TMP"
python3 - "$RESP_TMP" <<'PY'
import json, sys
from collections import defaultdict

with open(sys.argv[1], "r", encoding="utf-8") as f:
    rows = json.loads(f.read() or "[]")
groups = defaultdict(list)
for r in rows:
    art = (r.get("artifact_name") or "").strip().lower()
    com = (r.get("comment") or "").strip()
    key = f"{art}|{com[:80].lower()}"
    groups[key].append(r)

for items in groups.values():
    if len(items) != 1:
        continue
    r = items[0]
    out = {
        "feedback_id": r["id"],
        "customer_id": r.get("customer_id"),
        "artifact_name": r.get("artifact_name") or "",
        "quote": r.get("quote") or "",
        "comment": r.get("comment") or "",
    }
    print(json.dumps(out, ensure_ascii=False))
PY
