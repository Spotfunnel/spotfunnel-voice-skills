#!/bin/bash
# scripts/ultravox-create-agent.sh
#
# POST a new Ultravox agent built from:
#   - a system-prompt markdown file
#   - a reference-settings.json (from ultravox-get-reference.sh)
#
# Used by Stage 6 of /base-agent.
#
# Args:
#   --name <agent_name>            (required) Ultravox agent display name
#   --system-prompt-file <path>    (required) path to system-prompt.md
#   --settings-file <path>         (required) path to reference-settings.json
#   --out <dir>                    (required) directory to save response JSON
#   --help                         print usage
#
# Hard rules:
#   - NEVER PATCH. Two runs against the same customer = two new agents.
#     Tracking which agent_id is "current" is the calling skill's job.
#   - selectedTools is always sent as []. The reference agent may have tools;
#     we deliberately strip them so the rough agent has no action surface.
#   - callTemplate.eventMessages is sent as []. call.ended webhook wiring is
#     done manually in the Ultravox console per the design doc.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/ultravox-create-agent.sh \
    --name <agent_name> \
    --system-prompt-file <path> \
    --settings-file <path> \
    --out <dir>

Required:
  --name <agent_name>            Ultravox name (must be non-empty)
  --system-prompt-file <path>    Path to the system prompt markdown
  --settings-file <path>         Path to reference-settings.json
  --out <dir>                    Directory to write agent-created.json into

Behavior: POSTs https://api.ultravox.ai/api/agents and saves the full
response. selectedTools and eventMessages are always [] regardless of what
the reference agent had.

NEVER PATCHES. Re-running creates a NEW agent.
EOF
}

NAME=""
PROMPT_FILE=""
SETTINGS_FILE=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      NAME="${2:-}"
      shift 2
      ;;
    --system-prompt-file)
      PROMPT_FILE="${2:-}"
      shift 2
      ;;
    --settings-file)
      SETTINGS_FILE="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
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

# Per spec: empty --name fails BEFORE we touch the network.
if [ -z "$NAME" ]; then
  echo "[ERR] --name is required and must be non-empty" >&2
  exit 1
fi
if [ -z "$PROMPT_FILE" ]; then
  echo "[ERR] --system-prompt-file is required" >&2
  exit 1
fi
if [ -z "$SETTINGS_FILE" ]; then
  echo "[ERR] --settings-file is required" >&2
  exit 1
fi
if [ -z "$OUT_DIR" ]; then
  echo "[ERR] --out is required" >&2
  exit 1
fi
if [ ! -f "$PROMPT_FILE" ]; then
  echo "[ERR] system prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "[ERR] settings file not found: $SETTINGS_FILE" >&2
  exit 1
fi

# Source env (resolves ULTRAVOX_API_KEY).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

mkdir -p "$OUT_DIR"

echo "[INFO] building Ultravox create-agent payload for name=$NAME"

PAYLOAD_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE" "$RESP_FILE"' EXIT

# Build the payload in Python so we can cleanly merge structured settings
# with the prompt file content (avoids shell-quoting hell on multi-line
# markdown).
python3 - "$NAME" "$PROMPT_FILE" "$SETTINGS_FILE" "$PAYLOAD_FILE" <<'PY'
import json, sys

name, prompt_path, settings_path, payload_path = sys.argv[1:5]

with open(prompt_path, "r", encoding="utf-8") as f:
    system_prompt = f.read()

with open(settings_path, "r", encoding="utf-8") as f:
    settings = json.load(f)

# callTemplate is the wholesale-replace block on Ultravox — every field we
# want must be in here. Mirror VAM's UltravoxClient._call_template shape.
call_template = {
    "systemPrompt": system_prompt,
    # selectedTools is ALWAYS [] regardless of reference. The rough agent
    # has no action tools — that's by design.
    "selectedTools": [],
    # Note: eventMessages is no longer accepted by Ultravox MultistageCallTemplate
    # — call.ended webhooks are wired in the Ultravox console post-create.
}

# Pull through fields if the reference provided them. Skip nulls so we
# don't override Ultravox defaults with explicit None.
def maybe_set(key, src_key=None):
    src_key = src_key or key
    if src_key in settings and settings[src_key] is not None:
        call_template[key] = settings[src_key]

maybe_set("voice")
maybe_set("model")
maybe_set("languageHint")
maybe_set("temperature")
maybe_set("inactivityMessages")
maybe_set("vadSettings")
maybe_set("voiceOverrides")
maybe_set("recordingEnabled")

# firstSpeakerSettings is the modern object-discriminator form; some
# reference responses surface only the legacy "firstSpeaker" string.
# Prefer the object form when present; fall back to wrapping the string.
fss = settings.get("firstSpeakerSettings")
if isinstance(fss, dict) and fss:
    call_template["firstSpeakerSettings"] = fss
else:
    fs = settings.get("firstSpeaker")
    if isinstance(fs, str) and fs:
        # Common legacy values are "FIRST_SPEAKER_AGENT" / "FIRST_SPEAKER_USER".
        if "USER" in fs.upper():
            call_template["firstSpeakerSettings"] = {"user": {}}
        else:
            call_template["firstSpeakerSettings"] = {"agent": {}}

payload = {
    "name": name,
    "callTemplate": call_template,
}

with open(payload_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

echo "[INFO] POSTing https://api.ultravox.ai/api/agents"

HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "https://api.ultravox.ai/api/agents" \
  -H "X-API-Key: $ULTRAVOX_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Ultravox POST agent returned HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  echo >&2
  exit 1
fi

OUT_PATH="$OUT_DIR/agent-created.json"
cp "$RESP_FILE" "$OUT_PATH"

AGENT_ID="$(python3 - "$RESP_FILE" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
# Ultravox's create-agent response uses "agentId" in current API; fall back
# to "id" defensively in case the field naming changes.
print(data.get("agentId") or data.get("id") or "")
PY
)"

if [ -z "$AGENT_ID" ]; then
  echo "[ERR] Ultravox returned 2xx but response had no agentId/id" >&2
  cat "$RESP_FILE" >&2
  echo >&2
  exit 1
fi

echo "[OK] agent created: id=$AGENT_ID, name=$NAME"
echo "[INFO] response saved to $OUT_PATH"
exit 0
