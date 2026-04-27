#!/usr/bin/env bash
# scripts/refine-elevate-cluster.sh <feedback_id_csv> <title> <pattern> <fix>
#
# Generate the next L-NNN id, insert a row into operator_ui.lessons with the
# given title/pattern/fix, then mark each feedback id in the CSV as elevated
# (status='elevated', elevated_to_lesson_id=<L-NNN>).
#
# Stdout: the new lesson id.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

CSV="${1:-}"
TITLE="${2:-}"
PATTERN="${3:-}"
FIX="${4:-}"
if [ -z "$CSV" ] || [ -z "$TITLE" ] || [ -z "$PATTERN" ] || [ -z "$FIX" ]; then
  echo "Usage: refine-elevate-cluster.sh <feedback_id_csv> <title> <pattern> <fix>" >&2
  exit 1
fi

# Resolve customer_ids of the source feedback rows so the lesson can record
# observed_in_customer_ids accurately.
IDS_JSON="$(python3 -c '
import json, sys
csv = sys.argv[1]
print(json.dumps([s.strip() for s in csv.split(",") if s.strip()]))
' "$CSV")"
ID_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$IDS_JSON")"
if [ "$ID_COUNT" -eq 0 ]; then
  echo "refine-elevate-cluster: feedback_id_csv had no ids" >&2
  exit 1
fi

# PostgREST `in.()` filter for the feedback ids.
IN_FILTER="$(python3 -c '
import json, sys, urllib.parse
ids = json.loads(sys.argv[1])
inner = ",".join(urllib.parse.quote(i, safe="") for i in ids)
print(f"in.({inner})")
' "$IDS_JSON")"

FB_ROWS="$(supabase_get "feedback?id=${IN_FILTER}&select=id,customer_id")"
FOUND="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$FB_ROWS")"
if [ "$FOUND" -ne "$ID_COUNT" ]; then
  echo "refine-elevate-cluster: expected $ID_COUNT feedback rows, found $FOUND" >&2
  exit 1
fi
CUSTOMER_IDS_JSON="$(python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
seen = []
for r in rows:
    cid = r.get("customer_id")
    if cid and cid not in seen:
        seen.append(cid)
print(json.dumps(seen))
' "$FB_ROWS")"

# Next L-NNN id. Atomic-ish via select max + increment.
EXISTING="$(supabase_get "lessons?id=like.L-%25&select=id&order=id.desc&limit=1")"
NEW_ID="$(python3 -c '
import json, re, sys
rows = json.loads(sys.argv[1] or "[]")
if not rows:
    print("L-001"); sys.exit(0)
m = re.match(r"^L-(\d+)$", rows[0]["id"])
n = int(m.group(1)) + 1 if m else 1
print(f"L-{n:03d}")
' "$EXISTING")"

LESSON_BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "id": sys.argv[1],
    "title": sys.argv[2],
    "pattern": sys.argv[3],
    "fix": sys.argv[4],
    "observed_in_customer_ids": json.loads(sys.argv[5]),
    "source_feedback_ids": json.loads(sys.argv[6]),
    "promoted_to_prompt": False,
}))
' "$NEW_ID" "$TITLE" "$PATTERN" "$FIX" "$CUSTOMER_IDS_JSON" "$IDS_JSON")"

LESSON_RESP="$(supabase_post "lessons" "$LESSON_BODY")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not isinstance(d, list) or not d or d[0].get("id") != sys.argv[2]:
    sys.stderr.write(f"refine-elevate-cluster: lesson insert failed: {sys.argv[1]}\n")
    sys.exit(1)
' "$LESSON_RESP" "$NEW_ID"

# Mark each feedback row elevated.
PATCH_BODY="$(python3 -c '
import json, sys
print(json.dumps({"status": "elevated", "elevated_to_lesson_id": sys.argv[1]}))
' "$NEW_ID")"
supabase_patch "feedback?id=${IN_FILTER}" "$PATCH_BODY" >/dev/null

echo "$NEW_ID"
