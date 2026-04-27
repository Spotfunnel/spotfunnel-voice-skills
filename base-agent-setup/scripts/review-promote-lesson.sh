#!/usr/bin/env bash
# scripts/review-promote-lesson.sh <lesson_id> <prompt_file_path>
#
# Phase 2 of /base-agent review-feedback: bake a mature lesson into a
# generator prompt file.
#
# Steps (ordered for safe partial-failure recovery):
#   1. Fetch the lesson row.
#   2. PATCH the lesson row: promoted_to_prompt=true, promoted_at=now(),
#      promoted_to_file=<path>. Done first as the cheapest probe of "can I
#      still talk to Supabase" — failing here leaves the prompt file
#      untouched, no recovery needed.
#   3. Append "### From <id>: <title> (promoted YYYY-MM-DD)\n\n<fix>\n" under
#      the "## Lessons learned (do not regenerate)" section in the prompt
#      file. Create that section at end of file if missing. Write is atomic
#      (tmp + os.replace) — either succeeds completely or leaves the file
#      untouched.
#   4. DELETE the lesson row (per design — once it's in the prompt body, the
#      runtime fetcher no longer needs it). If this fails, the row remains
#      with promoted_to_prompt=true so the next review-feedback run skips
#      it (only lists promoted_to_prompt=false). Recoverable, harmless
#      artifact.
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

# 1. PATCH first — cheapest probe of "can I still talk to Supabase".
#    If it fails, the prompt file is untouched and there is nothing to
#    recover. Mark the lesson promoted (audit trail).
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

# 2. Append to prompt file. Create section if missing. Write is atomic
#    (tmp + os.replace) — single MoveFileEx on Windows / rename(2) on POSIX
#    — so a Ctrl-C / OneDrive-sync / antivirus / OS-crash mid-write cannot
#    leave the prompt file truncated or zero-length. On any earlier failure
#    the .tmp file remains as a breadcrumb.
#
#    The "### From <id>:" guard below is load-bearing recovery infra for
#    partial-failure replay: if step 3 (DELETE) failed on a previous run,
#    the lesson is already PATCHed promoted=true AND the prompt file
#    already contains its entry, so a re-run of review-feedback would
#    skip the row (only lists promoted=false). But if an operator manually
#    flips promoted_to_prompt back to false to retry, the guard prevents a
#    second copy of the same entry from corrupting the prompt body.
python3 - "$PROMPT_PATH" "$LESSON_ID" "$TITLE" "$FIX" "$TODAY" <<'PY'
import os
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

# Atomic write: write to .tmp sibling, then os.replace (single MoveFileEx
# on Windows, rename(2) on POSIX). Either the original file or the new
# file is visible at all times — never a truncated zero-length artifact.
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(body, encoding="utf-8")
os.replace(tmp, path)
PY

# 3. DELETE — row is no longer needed at runtime; fix lives in the prompt
#    file. If this fails, the row remains promoted_to_prompt=true with
#    promoted_at / promoted_to_file set. The next review-feedback run will
#    skip it (review-list-lessons.sh only lists promoted_to_prompt=false),
#    so the operator just sees an artifact-not-cleaned-up state — harmless
#    and recoverable by a manual delete.
DEL_RESP="$(supabase_delete "lessons?id=eq.${LESSON_ID}")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1] or "[]")
if not isinstance(d, list) or len(d) != 1:
    sys.stderr.write(f"review-promote-lesson: DELETE returned {sys.argv[1]}\n")
    sys.exit(1)
' "$DEL_RESP"

echo "OK $LESSON_ID"
