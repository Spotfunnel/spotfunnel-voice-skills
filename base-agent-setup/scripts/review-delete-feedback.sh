#!/usr/bin/env bash
# scripts/review-delete-feedback.sh <feedback_id_csv>
#
# Physically delete feedback rows. Used by /base-agent review-feedback
# phase 1 when the operator decides a cluster or singleton isn't a real
# issue (D — delete).
#
# Halts loud if the DELETE returns fewer rows than asked.
#
# Stdout: count of rows deleted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

CSV="${1:-}"
if [ -z "$CSV" ]; then
  echo "Usage: review-delete-feedback.sh <feedback_id_csv>" >&2
  exit 1
fi

IDS_JSON="$(python3 -c '
import json, sys
csv = sys.argv[1]
print(json.dumps([s.strip() for s in csv.split(",") if s.strip()]))
' "$CSV")"
ID_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$IDS_JSON")"
if [ "$ID_COUNT" -eq 0 ]; then
  echo "review-delete-feedback: feedback_id_csv had no ids" >&2
  exit 1
fi

IN_FILTER="$(python3 -c '
import json, sys, urllib.parse
ids = json.loads(sys.argv[1])
inner = ",".join(urllib.parse.quote(i, safe="") for i in ids)
print(f"in.({inner})")
' "$IDS_JSON")"

RESP="$(supabase_delete "feedback?id=${IN_FILTER}")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1] or "[]")
expected = int(sys.argv[2])
got = len(d) if isinstance(d, list) else 0
if got != expected:
    sys.stderr.write(
        f"review-delete-feedback: deleted {got} rows, expected {expected}. "
        f"Response: {sys.argv[1]}\n"
    )
    sys.exit(1)
print(got)
' "$RESP" "$ID_COUNT"
