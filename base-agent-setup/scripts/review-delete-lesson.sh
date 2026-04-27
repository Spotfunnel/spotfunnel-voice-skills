#!/usr/bin/env bash
# scripts/review-delete-lesson.sh <lesson_id>
#
# Physically delete a single lesson row. Used by /base-agent review-feedback
# phase 2 when the operator decides a lesson turned out wrong / superseded.
#
# Stdout: OK <lesson_id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

LESSON_ID="${1:-}"
if [ -z "$LESSON_ID" ]; then
  echo "Usage: review-delete-lesson.sh <lesson_id>" >&2
  exit 1
fi

RESP="$(supabase_delete "lessons?id=eq.${LESSON_ID}")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1] or "[]")
if not isinstance(d, list) or len(d) != 1:
    sys.stderr.write(f"review-delete-lesson: DELETE returned {sys.argv[1]}\n")
    sys.exit(1)
' "$RESP"

echo "OK $LESSON_ID"
