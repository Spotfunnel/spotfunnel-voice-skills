#!/usr/bin/env bash
# scripts/refine-record-feedback.sh <annotation_id> [comment_override]
#
# Read an annotation, generate the next F-YYYY-MM-DD-NNN id, insert a row
# into operator_ui.feedback. Provenance is the source annotation
# (run_id, customer_id, artifact_name, quote, comment).
#
# If <comment_override> is supplied, it replaces the annotation comment in
# the feedback row (used when the operator splits a mixed annotation and
# only the behavior half matters).
#
# Stdout: the new feedback id.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

AID="${1:-}"
OVERRIDE="${2:-}"
if [ -z "$AID" ]; then
  echo "Usage: refine-record-feedback.sh <annotation_id> [comment_override]" >&2
  exit 1
fi

ANN="$(supabase_get "annotations?id=eq.${AID}&select=run_id,artifact_name,quote,comment")"
ANN_ROW="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else "")' <<<"$ANN")"
if [ -z "$ANN_ROW" ]; then
  echo "refine-record-feedback: annotation $AID not found" >&2
  exit 1
fi

RUN_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["run_id"])' "$ANN_ROW")"
ART_NAME="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["artifact_name"])' "$ANN_ROW")"
QUOTE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["quote"])' "$ANN_ROW")"
COMMENT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["comment"])' "$ANN_ROW")"
if [ -n "$OVERRIDE" ]; then
  COMMENT="$OVERRIDE"
fi

CUSTOMER_ID="$(supabase_get "runs?id=eq.${RUN_ID}&select=customer_id" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["customer_id"] if d else "")')"
if [ -z "$CUSTOMER_ID" ]; then
  echo "refine-record-feedback: customer for run $RUN_ID not found" >&2
  exit 1
fi

TODAY="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%d"))')"
PREFIX="F-${TODAY}-"

# Find the highest existing F-YYYY-MM-DD-NNN id for today and increment.
EXISTING="$(supabase_get "feedback?id=like.${PREFIX}%25&select=id&order=id.desc&limit=1")"
NEXT_NUM="$(python3 -c '
import json, re, sys
rows = json.loads(sys.argv[1] or "[]")
if not rows:
    print(1); sys.exit(0)
m = re.match(r"^F-\d{4}-\d{2}-\d{2}-(\d+)$", rows[0]["id"])
print(int(m.group(1)) + 1 if m else 1)
' "$EXISTING")"
NEW_ID="$(printf '%s%03d' "$PREFIX" "$NEXT_NUM")"

BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "id": sys.argv[1],
    "customer_id": sys.argv[2],
    "run_id": sys.argv[3],
    "source_annotation_id": sys.argv[4],
    "artifact_name": sys.argv[5],
    "quote": sys.argv[6],
    "comment": sys.argv[7],
}))
' "$NEW_ID" "$CUSTOMER_ID" "$RUN_ID" "$AID" "$ART_NAME" "$QUOTE" "$COMMENT")"

RESP="$(supabase_post "feedback" "$BODY")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not isinstance(d, list) or not d or d[0].get("id") != sys.argv[2]:
    sys.stderr.write(f"refine-record-feedback: insert failed: {sys.argv[1]}\n")
    sys.exit(1)
' "$RESP" "$NEW_ID"

echo "$NEW_ID"
