#!/bin/bash
# scripts/wire-ultravox-telephony.sh
#
# Point the TeXML app a DID is bound to at an Ultravox agent, completing
# the final hop in the inbound-call chain:
#
#   PSTN  ->  Telnyx DID  ->  TeXML app  ->  Ultravox agent telephony_xml
#
# Pool model: one TeXML app per DID, set up once by
# `bulk-create-texml-apps.sh`. This script resolves the DID's TeXML app at
# runtime (GET phone_number) and PATCHes that app's voice_url. Because the
# app is dedicated to a single DID, the PATCH only ever affects this one
# customer.
#
# Args:
#   --did <+E.164>             required.
#   --ultravox-agent-id <id>   required.
#   --out <dir>                required.
#   --help                     print usage.
#
# Env:
#   TELNYX_API_KEY             required.
#
# Writes <out>/telephony-wired.json with verification. Exit 1 on any
# Telnyx error.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/wire-ultravox-telephony.sh \
    --did <+E.164> \
    --ultravox-agent-id <id> \
    --out <dir>

PATCHes the TeXML app the DID is bound to so its voice_url points at
https://app.ultravox.ai/api/agents/{ultravox-agent-id}/telephony_xml.
GETs the app back and verifies the URL was set. Writes telephony-wired.json.
EOF
}

DID=""
AGENT_ID=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --did)
      DID="${2:-}"
      shift 2
      ;;
    --ultravox-agent-id)
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

if [ -z "$DID" ]; then
  echo "[ERR] --did is required" >&2
  exit 1
fi
if [ -z "$AGENT_ID" ]; then
  echo "[ERR] --ultravox-agent-id is required" >&2
  exit 1
fi
if [ -z "$OUT_DIR" ]; then
  echo "[ERR] --out is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

mkdir -p "$OUT_DIR"

NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

VOICE_URL="https://app.ultravox.ai/api/agents/$AGENT_ID/telephony_xml"

# ----- Step 1: resolve which TeXML app this DID is bound to -----
PN_RESP="$(mktemp)"
PATCH_RESP="$(mktemp)"
GET_RESP="$(mktemp)"
trap 'rm -f "$PN_RESP" "$PATCH_RESP" "$GET_RESP"' EXIT

echo "[INFO] resolving TeXML app for DID $DID"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$PN_RESP" -w "%{http_code}" \
  -G "https://api.telnyx.com/v2/phone_numbers" \
  --data-urlencode "filter[phone_number]=$DID" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET phone_numbers returned HTTP $HTTP_CODE" >&2
  cat "$PN_RESP" >&2
  echo >&2
  exit 1
fi

TEXML_APP_ID="$(python3 - "$PN_RESP" "$DID" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    body = json.load(f)
target = sys.argv[2]
data = body.get("data") or []
hit = next((n for n in data if n.get("phone_number") == target), None)
print(hit.get("connection_id") if hit else "")
PY
)"

if [ -z "$TEXML_APP_ID" ]; then
  echo "[ERR] DID $DID has no connection_id (TeXML app) bound — run telnyx-wire-texml.sh first" >&2
  exit 1
fi

echo "[INFO] DID $DID is bound to TeXML app $TEXML_APP_ID"

# ----- Step 2: PATCH voice_url -----
PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"voice_url": sys.argv[1], "voice_method": "post"}))' "$VOICE_URL")"

echo "[INFO] PATCH texml_applications/$TEXML_APP_ID voice_url -> $VOICE_URL"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$PATCH_RESP" -w "%{http_code}" \
  -X PATCH "https://api.telnyx.com/v2/texml_applications/$TEXML_APP_ID" \
  -H "Authorization: Bearer $TELNYX_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx PATCH texml_applications returned HTTP $HTTP_CODE" >&2
  cat "$PATCH_RESP" >&2
  echo >&2
  exit 1
fi

# ----- Step 3: GET back, verify the URL took -----
echo "[INFO] verifying voice_url via GET texml_applications/$TEXML_APP_ID"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$GET_RESP" -w "%{http_code}" \
  -X GET "https://api.telnyx.com/v2/texml_applications/$TEXML_APP_ID" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET texml_applications returned HTTP $HTTP_CODE" >&2
  cat "$GET_RESP" >&2
  echo >&2
  exit 1
fi

ACTUAL_VOICE_URL="$(python3 - "$GET_RESP" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    body = json.load(f)
data = body.get("data") or {}
print(data.get("voice_url") or "")
PY
)"

if [ "$ACTUAL_VOICE_URL" != "$VOICE_URL" ]; then
  echo "[ERR] voice_url verification failed: expected '$VOICE_URL', got '$ACTUAL_VOICE_URL'" >&2
  cat "$GET_RESP" >&2
  echo >&2
  exit 1
fi

echo "[OK] voice_url set + verified: $ACTUAL_VOICE_URL"

# ----- Write telephony-wired.json -----
OUT_PATH="$OUT_DIR/telephony-wired.json"

DID_VAL="$DID" \
AGENT_VAL="$AGENT_ID" \
TEXML_APP_VAL="$TEXML_APP_ID" \
URL_VAL="$ACTUAL_VOICE_URL" \
NOW_ISO_VAL="$NOW_ISO" \
python3 - "$OUT_PATH" <<'PY'
import json, os, sys
out_path = sys.argv[1]
payload = {
    "did": os.environ["DID_VAL"],
    "ultravox_agent_id": os.environ["AGENT_VAL"],
    "texml_app_id": os.environ["TEXML_APP_VAL"],
    "texml_voice_url": os.environ["URL_VAL"],
    "wired_at": os.environ["NOW_ISO_VAL"],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

echo "[INFO] wrote $OUT_PATH"
exit 0
