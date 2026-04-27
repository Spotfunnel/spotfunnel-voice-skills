#!/usr/bin/env bash
# scripts/tests/test_compose_prompt.sh
#
# Smoke tests for compose-prompt.sh (M23 Fix 8).
# Runs offline — fetch_lessons.py exits 0 with no stdout when SUPABASE_OPERATOR_URL
# is unset, so we drive the lessons-block paths via env manipulation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$SCRIPTS_DIR/compose-prompt.sh"

PASS=0
FAIL=0
FAILS=()

assert_contains() {
  # $1=needle, $2=haystack, $3=test_name
  if printf '%s' "$2" | grep -qF -- "$1"; then
    PASS=$((PASS + 1))
    echo "[PASS] $3"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("$3 — needle '$1' not found")
    echo "[FAIL] $3 — needle '$1' not found"
  fi
}

assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then
    FAIL=$((FAIL + 1))
    FAILS+=("$3 — unexpected '$1' found")
    echo "[FAIL] $3 — unexpected '$1' found"
  else
    PASS=$((PASS + 1))
    echo "[PASS] $3"
  fi
}

# Ensure fetch_lessons.py exits silent (no Supabase) so the compose-prompt
# lessons block falls through to "(no active lessons)".
unset SUPABASE_OPERATOR_URL
unset SUPABASE_OPERATOR_SERVICE_ROLE_KEY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ----- Test 1: prompt with no placeholders → passthrough unchanged -----
# Compare via files (not shell $(...) capture) so trailing newlines aren't
# stripped — passthrough must be byte-identical.
PROMPT1="$TMP/no-placeholders.md"
printf '# Plain prompt\n\nNo placeholders here. Just markdown.\n' > "$PROMPT1"
COMPOSED1_FILE="$TMP/composed-1.md"
bash "$COMPOSE" "$PROMPT1" > "$COMPOSED1_FILE"
if cmp -s "$PROMPT1" "$COMPOSED1_FILE"; then
  PASS=$((PASS + 1))
  echo "[PASS] passthrough — no placeholders, byte-identical output"
else
  FAIL=$((FAIL + 1))
  FAILS+=("passthrough — content differs")
  echo "[FAIL] passthrough — content differs"
  diff "$PROMPT1" "$COMPOSED1_FILE" || true
fi

# ----- Test 2: LESSONS_BLOCK placeholder + no DB → "(no active lessons)" -----
PROMPT2="$TMP/with-lessons.md"
printf '# Lessons-aware prompt\n\n{{LESSONS_BLOCK}}\n\nBody continues.\n' > "$PROMPT2"
COMPOSED="$(bash "$COMPOSE" "$PROMPT2")"
assert_contains "(no active lessons)" "$COMPOSED" "lessons placeholder → empty-stub when no DB"
assert_not_contains "{{LESSONS_BLOCK}}" "$COMPOSED" "lessons placeholder must be substituted"

# ----- Test 3: CORRECTIONS_BLOCK placeholder + JSONL fixture → block populated -----
PROMPT3="$TMP/with-corrections.md"
printf '# Refine-aware prompt\n\n{{LESSONS_BLOCK}}\n\n{{CORRECTIONS_BLOCK}}\n\nBody.\n' > "$PROMPT3"
JSONL="$TMP/corrections.jsonl"
{
  printf '%s\n' '{"quote": "Hours are 9-5", "comment": "Actually 8-6 since Jan"}'
  printf '%s\n' '{"quote": "Brisbane only", "comment": "Now also Sydney + Melbourne"}'
} > "$JSONL"
COMPOSED="$(bash "$COMPOSE" "$PROMPT3" --corrections "$JSONL")"
assert_contains "<corrections>" "$COMPOSED" "corrections block opens"
assert_contains "</corrections>" "$COMPOSED" "corrections block closes"
assert_contains "Hours are 9-5" "$COMPOSED" "first correction quote present"
assert_contains "Actually 8-6 since Jan" "$COMPOSED" "first correction comment present"
assert_contains "Brisbane only" "$COMPOSED" "second correction quote present"
assert_not_contains "{{CORRECTIONS_BLOCK}}" "$COMPOSED" "corrections placeholder must be substituted"

# ----- Test 4: CORRECTIONS_BLOCK present but no --corrections → empty replacement -----
PROMPT4="$TMP/with-corrections-only.md"
printf 'Before {{CORRECTIONS_BLOCK}} After\n' > "$PROMPT4"
COMPOSED="$(bash "$COMPOSE" "$PROMPT4")"
assert_not_contains "{{CORRECTIONS_BLOCK}}" "$COMPOSED" "corrections-only placeholder substituted"
# The stub between Before/After should be empty.
EXPECTED="Before  After"
if [ "$(printf '%s' "$COMPOSED" | tr -d '\n')" = "$EXPECTED" ]; then
  PASS=$((PASS + 1))
  echo "[PASS] corrections placeholder collapses to empty without --corrections"
else
  FAIL=$((FAIL + 1))
  FAILS+=("corrections placeholder did not collapse to empty: got '$COMPOSED'")
  echo "[FAIL] corrections placeholder did not collapse to empty"
fi

# ----- Test 5: malformed JSONL line → exit non-zero -----
PROMPT5="$TMP/with-corrections.md"
BADJSONL="$TMP/bad.jsonl"
printf '{"quote": "ok", "comment": "good"}\nNOT VALID JSON\n' > "$BADJSONL"
if bash "$COMPOSE" "$PROMPT5" --corrections "$BADJSONL" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILS+=("malformed JSONL must halt; exited 0")
  echo "[FAIL] malformed JSONL must halt"
else
  PASS=$((PASS + 1))
  echo "[PASS] malformed JSONL halts cleanly"
fi

# ----- Test 6: missing prompt file → exit non-zero -----
if bash "$COMPOSE" "$TMP/does-not-exist.md" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILS+=("missing prompt file must halt; exited 0")
  echo "[FAIL] missing prompt file must halt"
else
  PASS=$((PASS + 1))
  echo "[PASS] missing prompt file halts cleanly"
fi

echo ""
echo "compose-prompt.sh smoke tests: pass=$PASS, fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILS[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
