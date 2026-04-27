#!/usr/bin/env bash
# scripts/compose-prompt.sh <prompt-file> [--corrections <jsonl-file>]
#
# M23 Fix 8 — deterministic prompt composition. Replaces the load-bearing-LLM
# pattern (where SKILL.md asked the orchestrator to "run fetch_lessons.py
# and read its output, treat it as binding" and "construct a <correction>
# block") with a shell-level substitution against version-controlled
# placeholders. The LLM cannot "forget" a substitution it doesn't make.
#
# What it does:
#   1. Read <prompt-file>.
#   2. Replace `{{LESSONS_BLOCK}}` (if present) with the output of
#      `python3 scripts/fetch_lessons.py`. If the placeholder isn't in the
#      file, no-op for that section. Empty lessons → "(no active lessons)"
#      stub line so the placeholder is always replaced with SOMETHING (this
#      is what "deterministic" means — never leak the literal placeholder).
#   3. If --corrections <jsonl-file> is supplied, replace `{{CORRECTIONS_BLOCK}}`
#      with a formatted block. JSONL format: one JSON object per line with
#      at least `quote` + `comment` fields (matches refine-list-annotations.sh).
#      If --corrections is NOT supplied but the placeholder is in the file,
#      replace with empty string (the placeholder is for refine context only;
#      a fresh /base-agent run has nothing to correct).
#   4. Print composed prompt to stdout.
#
# Stdout: composed prompt body. Caller pipes/redirects as needed:
#   bash scripts/compose-prompt.sh prompts/synthesize-brain-doc.md > /tmp/composed.md
#
# Halt-on-error: missing prompt file, malformed JSONL, etc.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/compose-prompt.sh <prompt-file> [--corrections <jsonl-file>]

Substitutes {{LESSONS_BLOCK}} and (optionally) {{CORRECTIONS_BLOCK}}
placeholders in <prompt-file> and prints the composed result to stdout.

Required:
  <prompt-file>             Generator prompt with placeholders.

Optional:
  --corrections <jsonl>     JSONL file (one {quote, comment} per line)
                            populating {{CORRECTIONS_BLOCK}}. Without this
                            flag, that placeholder is replaced with empty.
EOF
}

PROMPT_FILE=""
CORRECTIONS_FILE=""

# Positional <prompt-file> first; flags after.
if [ $# -lt 1 ]; then
  print_usage >&2
  exit 1
fi

PROMPT_FILE="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --corrections)
      CORRECTIONS_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "[ERR] unknown arg: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$PROMPT_FILE" ]; then
  echo "[ERR] compose-prompt: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [ -n "$CORRECTIONS_FILE" ] && [ ! -f "$CORRECTIONS_FILE" ]; then
  echo "[ERR] compose-prompt: corrections file not found: $CORRECTIONS_FILE" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run fetch_lessons. Empty/error → empty string (it's advisory).
LESSONS_BLOCK="$(python3 "$SCRIPT_DIR/fetch_lessons.py" 2>/dev/null || true)"
if [ -z "$LESSONS_BLOCK" ]; then
  LESSONS_BLOCK="(no active lessons)"
fi

# Compose corrections block from JSONL if supplied.
CORRECTIONS_BLOCK=""
if [ -n "$CORRECTIONS_FILE" ]; then
  CORRECTIONS_BLOCK="$(python3 - "$CORRECTIONS_FILE" <<'PY'
import json, sys
path = sys.argv[1]
items = []
with open(path, "r", encoding="utf-8") as f:
    for ln, raw in enumerate(f, 1):
        s = raw.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"[ERR] compose-prompt: corrections line {ln} is not JSON: {e}\n")
            sys.exit(1)
        quote = (obj.get("quote") or "").strip().replace("\n", " ")
        comment = (obj.get("comment") or "").strip().replace("\n", " ")
        if not (quote or comment):
            continue
        # Cap quote length so the block doesn't bloat — operators sometimes
        # paste long excerpts. The comment carries the actionable bit.
        if len(quote) > 200:
            quote = quote[:197] + "..."
        items.append((quote, comment))

if not items:
    print("")
    sys.exit(0)

out = ["<corrections>"]
out.append("The operator marked these facts wrong in the previous run. Apply them verbatim:")
for quote, comment in items:
    out.append(f"- Operator note on \"{quote}\": {comment}")
out.append("</corrections>")
print("\n".join(out))
PY
  )"
fi

# Substitute. Use Python so we don't have to escape & deal with sed special
# chars across multi-line content. Write to stdout in BINARY mode so we
# preserve exact line endings — Python on Windows otherwise translates LF
# → CRLF on text-mode stdout, breaking byte-identical passthrough.
PROMPT_FILE_IN="$PROMPT_FILE" \
LESSONS_IN="$LESSONS_BLOCK" \
CORRECTIONS_IN="$CORRECTIONS_BLOCK" \
python3 - <<'PY'
import os, sys

with open(os.environ["PROMPT_FILE_IN"], "rb") as f:
    body = f.read()

lessons = os.environ["LESSONS_IN"].encode("utf-8")
corrections = os.environ["CORRECTIONS_IN"].encode("utf-8")
body = body.replace(b"{{LESSONS_BLOCK}}", lessons)
body = body.replace(b"{{CORRECTIONS_BLOCK}}", corrections)

# Bypass text-mode stdout's newline translation on Windows.
sys.stdout.buffer.write(body)
PY
