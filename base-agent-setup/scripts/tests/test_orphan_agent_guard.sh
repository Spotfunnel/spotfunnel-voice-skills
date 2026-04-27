#!/usr/bin/env bash
# scripts/tests/test_orphan_agent_guard.sh
#
# M23 Fix 2 — unit test for ultravox-create-agent.sh's orphan-agent guard.
# Stubs `curl` on PATH so the script's precheck GET sees a fixture response
# with a name match, then asserts the script short-circuits to "agent re-used"
# without ever attempting a POST.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPTS_DIR/ultravox-create-agent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The script reads the live agent name; we'll claim "AcmeCo-Steve" already
# exists with id agent-existing-123.
EXPECTED_NAME="AcmeCo-Steve"
EXPECTED_ID="agent-existing-123"

# Build a curl stub that:
#   - on GET ...api/agents?... returns the fixture JSON containing our name
#   - on POST ...api/agents flat-out fails (the test must NOT reach POST)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# Stubbed curl for orphan-guard test.
HTTP_CODE_FILE=""
URL_TARGET=""
DATA_BIN=""
BODY=""
METHOD="GET"
OUT_FILE="/dev/null"

# Walk args so we can intercept:
#   - the URL (last positional)
#   - -X <method>
#   - -o <file>
#   - -w "%{http_code}"  (just emit "200" on stdout at the end)
#   - --data-binary @<file>
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2;;
    -o) OUT_FILE="\$2"; shift 2;;
    -w) shift 2;;
    -H) shift 2;;
    --data-binary) DATA_BIN="\$2"; shift 2;;
    --ssl-no-revoke) shift;;
    -sS) shift;;
    *) URL_TARGET="\$1"; shift;;
  esac
done

if [ "\$METHOD" = "POST" ]; then
  echo "[ORPHAN-GUARD-TEST] FAIL — script reached a POST despite name match" >&2
  exit 99
fi

# GET path: write the fixture body to OUT_FILE, emit 200 on stdout.
cat > "\$OUT_FILE" <<JSON
{
  "results": [
    {"agentId": "agent-other-1", "name": "OtherCustomer-Steve"},
    {"agentId": "$EXPECTED_ID", "name": "$EXPECTED_NAME"},
    {"agentId": "agent-other-2", "name": "ThirdCustomer-Jack"}
  ],
  "nextCursor": ""
}
JSON
printf '200'
EOF
chmod +x "$TMP/bin/curl"

# Provide a stub env-check.sh sourced by ultravox-create-agent.sh so we
# don't need real env vars beyond ULTRAVOX_API_KEY.
PROMPT="$TMP/sysprompt.md"
SETTINGS="$TMP/settings.json"
OUT="$TMP/out"
mkdir -p "$OUT"
printf 'You are an agent.' > "$PROMPT"
printf '%s' '{"voice":"Steve","temperature":0.4,"firstSpeaker":"FIRST_SPEAKER_AGENT"}' > "$SETTINGS"

# Run the script with our stubbed curl on PATH and a dummy api key.
PATH_BACKUP="$PATH"
export PATH="$TMP/bin:$PATH_BACKUP"
export ULTRAVOX_API_KEY="dummy-key-for-test"

set +e
OUTPUT="$(bash "$TARGET" \
  --name "$EXPECTED_NAME" \
  --system-prompt-file "$PROMPT" \
  --settings-file "$SETTINGS" \
  --out "$OUT" 2>&1)"
RC=$?
set -e

export PATH="$PATH_BACKUP"

if [ "$RC" -ne 0 ]; then
  echo "[FAIL] orphan-guard expected exit 0, got $RC. Output:" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

if ! printf '%s' "$OUTPUT" | grep -q "Ultravox already has an agent named '$EXPECTED_NAME'"; then
  echo "[FAIL] orphan-guard did not log the expected re-use message" >&2
  echo "Output: $OUTPUT" >&2
  exit 1
fi

if ! printf '%s' "$OUTPUT" | grep -q "agent re-used (orphan guard)"; then
  echo "[FAIL] orphan-guard did not print the OK marker" >&2
  echo "Output: $OUTPUT" >&2
  exit 1
fi

# The agent-created.json should hold the EXISTING agent's body.
if [ ! -f "$OUT/agent-created.json" ]; then
  echo "[FAIL] orphan-guard did not write agent-created.json" >&2
  exit 1
fi
if ! grep -q "$EXPECTED_ID" "$OUT/agent-created.json"; then
  echo "[FAIL] agent-created.json should contain $EXPECTED_ID; got:" >&2
  cat "$OUT/agent-created.json" >&2
  exit 1
fi

echo "[PASS] orphan-agent guard short-circuits on name match"
exit 0
