#!/usr/bin/env bash
# scripts/review-promote-lesson.sh <lesson_id> <prompt_file_path> [--force]
#
# Phase 2 of /base-agent review-feedback: bake a mature lesson into a
# generator prompt file.
#
# Steps (ordered for safe partial-failure recovery):
#   1. Fetch the lesson row.
#   1a. M23 Fix 7A — sanitize: scan title+pattern+fix for prompt-injection
#       patterns. Hard-block on injection markers; soft-warn on triple
#       backticks (require --force).
#   1b. M23 Fix 7B — contradiction guard: read existing unpromoted lessons
#       AND the target prompt file's "## Lessons learned" section, scan for
#       direct-negation phrases against the new lesson, warn (not block).
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
FORCE_FLAG=0
# Optional --force flag: bypasses soft-warn (triple-backtick) and the
# contradiction-guard warning. Hard-block injection patterns ALWAYS halt
# — --force does not bypass them; the operator must edit the lesson row
# directly via Supabase if they truly want that text.
if [ "${3:-}" = "--force" ]; then
  FORCE_FLAG=1
fi
if [ -z "$LESSON_ID" ] || [ -z "$PROMPT_PATH" ]; then
  echo "Usage: review-promote-lesson.sh <lesson_id> <prompt_file_path> [--force]" >&2
  exit 1
fi
if [ ! -f "$PROMPT_PATH" ]; then
  echo "review-promote-lesson: prompt file not found: $PROMPT_PATH" >&2
  exit 1
fi

LESSON="$(supabase_get "lessons?id=eq.${LESSON_ID}&select=id,title,pattern,fix")"
LESSON_ROW="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else "")' <<<"$LESSON")"
if [ -z "$LESSON_ROW" ]; then
  echo "review-promote-lesson: lesson $LESSON_ID not found" >&2
  exit 1
fi

TITLE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("title",""))' "$LESSON_ROW")"
PATTERN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("pattern",""))' "$LESSON_ROW")"
FIX="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("fix",""))' "$LESSON_ROW")"
TODAY="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%d"))')"
NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

# ----------------------------------------------------------------------------
# M23 Fix 7A — sanitization. Scan title+pattern+fix for injection markers.
# Hard-block patterns halt; --force does NOT bypass these. The operator must
# edit the lesson row in Supabase directly if they truly want such text.
# Soft-warn patterns (triple backticks) require --force.
# ----------------------------------------------------------------------------
SANITIZE_LESSON_ID="$LESSON_ID" \
SANITIZE_TITLE="$TITLE" \
SANITIZE_PATTERN="$PATTERN" \
SANITIZE_FIX="$FIX" \
SANITIZE_FORCE="$FORCE_FLAG" \
SANITIZE_PROMPT_PATH="$PROMPT_PATH" \
python3 - <<'PY'
import os
import re
import sys

lesson_id = os.environ["SANITIZE_LESSON_ID"]
title = os.environ["SANITIZE_TITLE"]
pattern_in = os.environ["SANITIZE_PATTERN"]
fix = os.environ["SANITIZE_FIX"]
force = os.environ["SANITIZE_FORCE"] == "1"
prompt_path = os.environ["SANITIZE_PROMPT_PATH"]

scanned = "\n".join([title, pattern_in, fix])

# Hard-block patterns: indicators of prompt-injection attempts.
# Case-insensitive. ALL of these halt — regardless of --force.
HARD_BLOCK = [
    (r"<\s*system\s*>", "<system> tag"),
    (r"</\s*system\s*>", "</system> tag"),
    (r"<\|[^|]*\|>", "<|...|> token-style tag"),
    (r"\bignore\s+previous\s+instructions\b", "'Ignore previous instructions'"),
    (r"\bdisregard\s+the\s+above\b", "'Disregard the above'"),
    (r"\bfrom\s+now\s+on\b", "'From now on'"),
    (r"(?m)^system\s*prompt\s*:", "literal 'system prompt:' header"),
    (r"(?m)^user\s*:", "literal 'user:' conversation marker"),
    (r"(?m)^assistant\s*:", "literal 'assistant:' conversation marker"),
    (r"\n\s*User\s*:", "newline-then-'User:' (conversation injection)"),
]
for rx, label in HARD_BLOCK:
    m = re.search(rx, scanned, re.IGNORECASE)
    if m:
        # Show the offending line for the operator's grep.
        line_start = scanned.rfind("\n", 0, m.start()) + 1
        line_end = scanned.find("\n", m.end())
        if line_end == -1:
            line_end = len(scanned)
        offender = scanned[line_start:line_end].strip()
        sys.stderr.write(
            f"review-promote-lesson: lesson {lesson_id} contains a pattern "
            f"that looks like prompt injection ({label}): "
            f"'{offender}'.\n"
            f"Refusing to write to {prompt_path}. Edit the lesson row "
            f"directly via Supabase if intentional, then re-run.\n"
        )
        sys.exit(1)

# Soft-warn patterns: triple backticks may be legitimate (operator quoting
# code) but they're a fence that can break out of an enclosing markdown
# context. Require --force to proceed.
if "```" in scanned and not force:
    sys.stderr.write(
        f"review-promote-lesson: lesson {lesson_id} contains triple backticks. "
        f"This MAY be legitimate (e.g. operator quoting a snippet), but a "
        f"stray fence can break out of the enclosing prompt's markdown "
        f"context. Re-run with --force to acknowledge and proceed.\n"
    )
    sys.exit(1)
PY

# ----------------------------------------------------------------------------
# M23 Fix 7B — contradiction guard. Heuristic: scan existing unpromoted
# lessons + the target prompt file's "## Lessons learned" section for direct
# negation pairs against the new lesson. Warn (not block) on hit; --force
# bypasses the warning.
# ----------------------------------------------------------------------------
EXISTING_LESSONS_RAW="$(python3 "$SCRIPT_DIR/fetch_lessons.py" 2>/dev/null || true)"

CONTRADICTION_LESSON_ID="$LESSON_ID" \
CONTRADICTION_TITLE="$TITLE" \
CONTRADICTION_PATTERN="$PATTERN" \
CONTRADICTION_FIX="$FIX" \
CONTRADICTION_PROMPT_PATH="$PROMPT_PATH" \
CONTRADICTION_EXISTING="$EXISTING_LESSONS_RAW" \
CONTRADICTION_FORCE="$FORCE_FLAG" \
python3 - <<'PY'
import os
import re
import sys

# Heuristic only — catches obvious "always X" / "never X" pairs and similar.
# This is NOT semantic contradiction detection; it's a tripwire for the
# common literal-flip case. Documented as such in the script comment above.
lesson_id = os.environ["CONTRADICTION_LESSON_ID"]
title = os.environ["CONTRADICTION_TITLE"]
pattern_in = os.environ["CONTRADICTION_PATTERN"]
fix = os.environ["CONTRADICTION_FIX"]
prompt_path = os.environ["CONTRADICTION_PROMPT_PATH"]
existing_raw = os.environ["CONTRADICTION_EXISTING"]
force = os.environ["CONTRADICTION_FORCE"] == "1"

new_text = " ".join([title, pattern_in, fix]).lower()

# Read the prompt file's "## Lessons learned" section, if present.
existing_in_file = ""
try:
    with open(prompt_path, "r", encoding="utf-8") as f:
        body = f.read()
    marker = "## Lessons learned (do not regenerate)"
    if marker in body:
        existing_in_file = body[body.find(marker):]
except Exception:
    pass

haystack = (existing_raw + "\n" + existing_in_file).lower()
if not haystack.strip():
    sys.exit(0)

# Direct negation pairs. Each tuple is (rx_for_new, rx_for_existing).
# If rx_for_new matches the new lesson AND rx_for_existing matches the
# combined existing lessons, flag a possible contradiction.
NEG_PAIRS = [
    (r"\balways\s+(\w+(?:\s+\w+){0,3})", lambda m: rf"\bnever\s+{re.escape(m.group(1))}"),
    (r"\bnever\s+(\w+(?:\s+\w+){0,3})",  lambda m: rf"\balways\s+{re.escape(m.group(1))}"),
    (r"\binclude\s+(\w+(?:\s+\w+){0,3})", lambda m: rf"\bexclude\s+{re.escape(m.group(1))}"),
    (r"\bexclude\s+(\w+(?:\s+\w+){0,3})", lambda m: rf"\binclude\s+{re.escape(m.group(1))}"),
    (r"\bdo\s+(\w+(?:\s+\w+){0,3})",       lambda m: rf"\b(?:do\s+not|don't)\s+{re.escape(m.group(1))}"),
    (r"\b(?:do\s+not|don't)\s+(\w+(?:\s+\w+){0,3})", lambda m: rf"\bdo\s+{re.escape(m.group(1))}"),
]

contradictions: list[tuple[str, str]] = []
for new_rx, existing_rx_builder in NEG_PAIRS:
    for m in re.finditer(new_rx, new_text):
        flipped = existing_rx_builder(m)
        existing_match = re.search(flipped, haystack)
        if existing_match:
            new_phrase = m.group(0)
            line_start = haystack.rfind("\n", 0, existing_match.start()) + 1
            line_end = haystack.find("\n", existing_match.end())
            if line_end == -1:
                line_end = len(haystack)
            existing_phrase = haystack[line_start:line_end].strip()
            contradictions.append((new_phrase, existing_phrase))

if contradictions and not force:
    sys.stderr.write(
        f"review-promote-lesson: possible contradiction with existing lesson(s):\n"
    )
    for new_p, existing_p in contradictions[:5]:
        sys.stderr.write(
            f"  New lesson says: '{new_p}'\n"
            f"  Existing says:   '{existing_p[:200]}'\n"
        )
    sys.stderr.write(
        "Re-run with --force to override. (Heuristic only — direct negation "
        "pairs like always/never. May yield false positives.)\n"
    )
    sys.exit(1)
PY

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
