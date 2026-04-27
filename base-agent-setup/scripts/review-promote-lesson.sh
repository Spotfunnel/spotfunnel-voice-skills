#!/usr/bin/env bash
# scripts/review-promote-lesson.sh <lesson_id> <prompt_file_path>
#
# Phase 2 of /base-agent review-feedback: bake a mature lesson into a
# generator prompt file.
#
# Steps:
#   1. Fetch the lesson row.
#   2. Append "### From <id>: <title> (promoted YYYY-MM-DD)\n\n<fix>\n" under
#      the "## Lessons learned (do not regenerate)" section in the prompt
#      file. Create that section at end of file if missing.
#   3. PATCH the lesson row: promoted_to_prompt=true, promoted_at=now(),
#      promoted_to_file=<path>.
#   4. DELETE the lesson row (per design — once it's in the prompt body, the
#      runtime fetcher no longer needs it).
#
# Stdout: OK <lesson_id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

LESSON_ID="${1:-}"
PROMPT_PATH="${2:-}"
if [ -z "$LESSON_ID" ] || [ -z "$PROMPT_PATH" ]; then
  echo "Usage: review-promote-lesson.sh <lesson_id> <prompt_file_path>" >&2
  exit 1
fi
if [ ! -f "$PROMPT_PATH" ]; then
  echo "review-promote-lesson: prompt file not found: $PROMPT_PATH" >&2
  exit 1
fi

LESSON="$(supabase_get "lessons?id=eq.${LESSON_ID}&select=id,title,fix")"
LESSON_ROW="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else "")' <<<"$LESSON")"
if [ -z "$LESSON_ROW" ]; then
  echo "review-promote-lesson: lesson $LESSON_ID not found" >&2
  exit 1
fi

TITLE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("title",""))' "$LESSON_ROW")"
FIX="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("fix",""))' "$LESSON_ROW")"
TODAY="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%d"))')"
NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

# Append to prompt file. Create section if missing. Idempotent on repeat by
# id check — if the exact "### From <id>:" header is already present, halt
# (re-running would double-append).
python3 - "$PROMPT_PATH" "$LESSON_ID" "$TITLE" "$FIX" "$TODAY" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lid, title, fix, today = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

body = path.read_text(encoding="utf-8")
header_marker = f"### From {lid}:"
if header_marker in body:
    sys.stderr.write(
        f"review-promote-lesson: '{header_marker}' already present in {path}; refusing to double-append.\n"
    )
    sys.exit(1)

section_marker = "## Lessons learned (do not regenerate)"
entry = f"\n### From {lid}: {title} (promoted {today})\n\n{fix}\n"

if section_marker in body:
    # Append at end of file — entries accumulate chronologically below the heading.
    if not body.endswith("\n"):
        body += "\n"
    body += entry
else:
    # Create the section at end of file.
    if not body.endswith("\n"):
        body += "\n"
    body += f"\n---\n\n{section_marker}\n\n_Auto-promoted from operator_ui.lessons. Do not edit by hand._\n{entry}"

path.write_text(body, encoding="utf-8")
PY

# Mark the lesson promoted (audit trail) — we delete right after, but the
# write makes intent legible if anyone reads the row mid-flow.
PATCH_BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "promoted_to_prompt": True,
    "promoted_at": sys.argv[1],
    "promoted_to_file": sys.argv[2],
}))
' "$NOW_ISO" "$PROMPT_PATH")"

PATCH_RESP="$(supabase_patch "lessons?id=eq.${LESSON_ID}" "$PATCH_BODY")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1] or "[]")
if not isinstance(d, list) or len(d) != 1:
    sys.stderr.write(f"review-promote-lesson: PATCH returned {sys.argv[1]}\n")
    sys.exit(1)
' "$PATCH_RESP"

# Delete — row is no longer needed at runtime; fix lives in the prompt file.
DEL_RESP="$(supabase_delete "lessons?id=eq.${LESSON_ID}")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1] or "[]")
if not isinstance(d, list) or len(d) != 1:
    sys.stderr.write(f"review-promote-lesson: DELETE returned {sys.argv[1]}\n")
    sys.exit(1)
' "$DEL_RESP"

echo "OK $LESSON_ID"
