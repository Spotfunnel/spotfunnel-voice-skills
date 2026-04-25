#!/bin/bash
# scripts/ultravox-get-reference.sh
#
# Pull settings from a known-good Ultravox reference agent (e.g. TelcoWorks-Jack)
# so we can clone its voice/temperature/firstSpeaker/etc. onto a new rough agent.
# Used by Stage 5 of /base-agent.
#
# Args:
#   --agent-id <id>   (default $REFERENCE_ULTRAVOX_AGENT_ID)
#   --out <dir>       (required) directory to write reference-settings.json into
#   --help            print usage
#
# Output:
#   <out>/reference-settings.json   curated subset of the agent's callTemplate
#
# We deliberately strip selectedTools — the rough agent goes out with no tools.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/ultravox-get-reference.sh --out <dir> [--agent-id <id>]

Required:
  --out <dir>         Directory to write reference-settings.json into

Optional:
  --agent-id <id>     Defaults to $REFERENCE_ULTRAVOX_AGENT_ID
  --help              Show this help and exit

Captures: voice, temperature, firstSpeakerSettings, inactivityMessages,
languageHint, model, vadSettings, voiceOverrides — selectedTools intentionally
captured but NOT propagated by the create-agent script (rough agent ships
with empty tools).
EOF
}

AGENT_ID=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-id)
      AGENT_ID="${2:-}"
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

if [ -z "$OUT_DIR" ]; then
  echo "[ERR] --out is required" >&2
  exit 1
fi

# Source env (resolves ULTRAVOX_API_KEY + REFERENCE_ULTRAVOX_AGENT_ID).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

if [ -z "$AGENT_ID" ]; then
  AGENT_ID="${REFERENCE_ULTRAVOX_AGENT_ID:-}"
fi
if [ -z "$AGENT_ID" ]; then
  echo "[ERR] no --agent-id and \$REFERENCE_ULTRAVOX_AGENT_ID is empty" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[INFO] fetching Ultravox reference agent $AGENT_ID"

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$RAW" -w "%{http_code}" \
  -X GET "https://api.ultravox.ai/api/agents/$AGENT_ID" \
  -H "X-API-Key: $ULTRAVOX_API_KEY")"

if [ "$HTTP_CODE" -ge 400 ]; then
  echo "[ERR] Ultravox GET agent returned HTTP $HTTP_CODE" >&2
  cat "$RAW" >&2
  echo >&2
  exit 1
fi

OUT_PATH="$OUT_DIR/reference-settings.json"

# Extract the fields we want into a flattened JSON. The Ultravox agent
# response nests speech settings under callTemplate; we mirror that shape so
# the create-agent script can drop them straight back into a callTemplate.
SUMMARY="$(python3 - "$RAW" "$OUT_PATH" <<'PY'
import json, sys

raw_path, out_path = sys.argv[1], sys.argv[2]
with open(raw_path, "r", encoding="utf-8") as f:
    agent = json.load(f)

ct = agent.get("callTemplate") or {}

# Some Ultravox responses keep voice as a nested object {voiceId, name, ...},
# others return a string. Capture whichever form is present.
voice = ct.get("voice") if "voice" in ct else agent.get("voice")

# firstSpeaker can live as either firstSpeakerSettings (object discriminator)
# or firstSpeaker (legacy string). Capture both if present so create-agent can
# decide which to send.
first_speaker_settings = ct.get("firstSpeakerSettings") or agent.get("firstSpeakerSettings")
first_speaker = ct.get("firstSpeaker") or agent.get("firstSpeaker")

settings = {
    "sourceAgentId": agent.get("agentId") or agent.get("id"),
    "voice": voice,
    "model": ct.get("model") or agent.get("model"),
    "languageHint": ct.get("languageHint") or agent.get("languageHint"),
    "temperature": ct.get("temperature") if "temperature" in ct else agent.get("temperature"),
    "firstSpeakerSettings": first_speaker_settings,
    "firstSpeaker": first_speaker,
    "inactivityMessages": ct.get("inactivityMessages") or agent.get("inactivityMessages") or [],
    "vadSettings": ct.get("vadSettings") or agent.get("vadSettings"),
    "voiceOverrides": ct.get("voiceOverrides") or agent.get("voiceOverrides"),
    "recordingEnabled": ct.get("recordingEnabled") if "recordingEnabled" in ct else agent.get("recordingEnabled"),
    # Captured but the create-agent script intentionally ships [] regardless.
    "selectedTools": ct.get("selectedTools") or agent.get("selectedTools") or [],
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)

# Build a compact summary line for stdout.
voice_id = ""
if isinstance(voice, dict):
    voice_id = voice.get("voiceId") or voice.get("name") or ""
elif isinstance(voice, str):
    voice_id = voice

temp = settings["temperature"]
model = settings["model"] or ""
inactivity_count = len(settings["inactivityMessages"])
print(f"{voice_id}\t{temp}\t{model}\t{inactivity_count}")
PY
)"

VOICE_ID="$(echo "$SUMMARY" | cut -f1)"
TEMPERATURE="$(echo "$SUMMARY" | cut -f2)"
MODEL="$(echo "$SUMMARY" | cut -f3)"
INACTIVITY_COUNT="$(echo "$SUMMARY" | cut -f4)"

echo "[OK] reference settings captured: voice=$VOICE_ID, temperature=$TEMPERATURE, model=$MODEL, inactivityMessages=$INACTIVITY_COUNT"
echo "[INFO] written to $OUT_PATH"
exit 0
