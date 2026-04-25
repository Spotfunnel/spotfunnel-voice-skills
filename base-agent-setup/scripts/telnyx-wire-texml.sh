#!/bin/bash
# scripts/telnyx-wire-texml.sh
#
# Verify the per-DID TeXML app is correctly configured: codec set,
# voice_method=POST, status_callback present, status_callback_method=POST.
#
# The TeXML app this script audits is the one the DID is *currently* bound
# to (resolved at runtime via GET /v2/phone_numbers). With the one-app-per-
# DID model produced by `bulk-create-texml-apps.sh`, the binding is set up
# at pool creation time and never changes — so we only need the DID.
#
# Args:
#   --did <+E.164>              required.
#   --texml-app-id <id>         optional override. Defaults to the
#                                 connection_id discovered on the DID.
#   --out <dir>                 required.
#   --help                      print usage.
#
# Env:
#   TELNYX_API_KEY              required.
#
# Behavior:
#   1. GET phone_number — capture its current connection_id (the TeXML app).
#   2. GET texml_application — verify codec + voice_method +
#      status_callback + status_callback_method.
#   3. Write texml-wired.json with the verification result.
#
# Codec mismatch is WARN-only. Missing/malformed status_callback is HARD
# FAIL — the call lifecycle webhook needs that URL to fire.
#
# Writes <out>/texml-wired.json. Exit 1 on any non-recoverable failure.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/telnyx-wire-texml.sh \
    --did <+E.164> \
    [--texml-app-id <id>] \
    --out <dir>

Discovers the TeXML app the DID is bound to (or uses --texml-app-id if
provided), audits codec + voice_method + status_callback +
status_callback_method, and writes texml-wired.json.
EOF
}

DID=""
TEXML_APP_ID_OVERRIDE=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --did)
      DID="${2:-}"
      shift 2
      ;;
    --texml-app-id)
      TEXML_APP_ID_OVERRIDE="${2:-}"
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
if [ -z "$OUT_DIR" ]; then
  echo "[ERR] --out is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

mkdir -p "$OUT_DIR"

NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

# ----- Step 1: GET phone_number, capture connection_id -----
PN_RESP="$(mktemp)"
APP_RESP="$(mktemp)"
trap 'rm -f "$PN_RESP" "$APP_RESP"' EXIT

echo "[INFO] looking up DID $DID in Telnyx phone_numbers"
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

PN_INFO="$(python3 - "$PN_RESP" "$DID" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    body = json.load(f)
target = sys.argv[2]
data = body.get("data") or []
hit = next((n for n in data if n.get("phone_number") == target), None)
if not hit:
    print("MISSING")
else:
    print(f"{hit.get('id') or ''}|{hit.get('connection_id') or ''}")
PY
)"

if [ "$PN_INFO" = "MISSING" ]; then
  echo "[ERR] DID $DID not found in this Telnyx account" >&2
  exit 1
fi

PN_ID="${PN_INFO%%|*}"
CURRENT_CONN="${PN_INFO##*|}"

if [ -n "$TEXML_APP_ID_OVERRIDE" ]; then
  TEXML_APP_ID="$TEXML_APP_ID_OVERRIDE"
  echo "[INFO] using --texml-app-id override: $TEXML_APP_ID (DID is bound to $CURRENT_CONN)"
else
  TEXML_APP_ID="$CURRENT_CONN"
fi

if [ -z "$TEXML_APP_ID" ]; then
  echo "[ERR] DID $DID has no connection_id (TeXML app) bound — run bulk-create-texml-apps.sh first" >&2
  exit 1
fi

DID_BOUND="true"
echo "[OK] DID $DID bound to TeXML app $TEXML_APP_ID"

# ----- Step 2: GET TeXML app, audit codec / voice_method / status_callback -----
echo "[INFO] fetching TeXML app $TEXML_APP_ID"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$APP_RESP" -w "%{http_code}" \
  -X GET "https://api.telnyx.com/v2/texml_applications/$TEXML_APP_ID" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET texml_applications returned HTTP $HTTP_CODE" >&2
  cat "$APP_RESP" >&2
  echo >&2
  exit 1
fi

APP_INFO="$(python3 - "$APP_RESP" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    body = json.load(f)
data = body.get("data") or {}

codecs = []
inbound = data.get("inbound") or {}
if isinstance(inbound, dict):
    raw = inbound.get("codecs") or []
    if isinstance(raw, list):
        codecs = [str(c) for c in raw]
codec_str = ",".join(codecs) if codecs else ""

# Status-callback location varies between Telnyx schema versions.
status_cb = (
    data.get("status_callback")
    or data.get("statusCallback")
    or ""
)
status_cb_method = (
    data.get("status_callback_method")
    or data.get("statusCallbackMethod")
    or ""
)
voice_method = (
    data.get("voice_method")
    or data.get("voiceMethod")
    or ""
)

known_ok = {"PCMU", "PCMA", "G722", "OPUS", "L16", "G711U", "G711A"}
codec_ok = False
if codecs:
    codec_ok = any(c.upper() in known_ok or c.upper().startswith("G711") or c.upper().startswith("L16") for c in codecs)

print(f"{codec_str}|||{int(codec_ok)}|||{status_cb}|||{status_cb_method}|||{voice_method}")
PY
)"

CODEC="${APP_INFO%%|||*}"
REST="${APP_INFO#*|||}"
CODEC_OK_INT="${REST%%|||*}"
REST="${REST#*|||}"
STATUS_CB="${REST%%|||*}"
REST="${REST#*|||}"
STATUS_CB_METHOD="${REST%%|||*}"
VOICE_METHOD="${REST#*|||}"

CODEC_OK="false"
if [ "$CODEC_OK_INT" = "1" ]; then
  CODEC_OK="true"
fi

if [ "$CODEC_OK" = "true" ]; then
  echo "[OK] codec(s)=[$CODEC]"
else
  echo "[WARN] codec(s)=[$CODEC] not in known-good set — ops decision (re-run bulk-create-texml-apps.sh to reset)"
fi

# voice_method audit (informational — bulk-create-texml-apps.sh sets it).
case "$(echo "$VOICE_METHOD" | tr '[:upper:]' '[:lower:]')" in
  post) echo "[OK] voice_method=POST" ;;
  *)    echo "[WARN] voice_method='$VOICE_METHOD' (expected POST)" ;;
esac

# status_callback validation.
STATUS_CB_OK="false"
case "$STATUS_CB" in
  http://*|https://*) STATUS_CB_OK="true" ;;
  *) STATUS_CB_OK="false" ;;
esac

if [ "$STATUS_CB_OK" = "true" ]; then
  echo "[OK] status_callback is set: $STATUS_CB"
else
  echo "[ERR] TeXML app $TEXML_APP_ID has no status_callback URL (or it's malformed: '$STATUS_CB')" >&2
  echo "[ERR] Re-run bulk-create-texml-apps.sh — it sets status_callback to \$DASHBOARD_SERVER_URL/webhooks/call-ended" >&2
fi

# status_callback_method audit.
STATUS_CB_METHOD_OK="false"
case "$(echo "$STATUS_CB_METHOD" | tr '[:upper:]' '[:lower:]')" in
  post) STATUS_CB_METHOD_OK="true" ;;
esac

if [ "$STATUS_CB_METHOD_OK" = "true" ]; then
  echo "[OK] status_callback_method=POST"
else
  echo "[WARN] status_callback_method='$STATUS_CB_METHOD' (expected POST)"
fi

# ----- Write texml-wired.json -----
OUT_PATH="$OUT_DIR/texml-wired.json"

DID_VAL="$DID" \
DID_BOUND_VAL="$DID_BOUND" \
CODEC_VAL="$CODEC" \
CODEC_OK_VAL="$CODEC_OK" \
STATUS_CB_VAL="$STATUS_CB" \
STATUS_CB_OK_VAL="$STATUS_CB_OK" \
STATUS_CB_METHOD_VAL="$STATUS_CB_METHOD" \
STATUS_CB_METHOD_OK_VAL="$STATUS_CB_METHOD_OK" \
VOICE_METHOD_VAL="$VOICE_METHOD" \
TEXML_APP_VAL="$TEXML_APP_ID" \
NOW_ISO_VAL="$NOW_ISO" \
python3 - "$OUT_PATH" <<'PY'
import json, os, sys
out_path = sys.argv[1]
payload = {
    "did": os.environ["DID_VAL"],
    "texml_app_id": os.environ["TEXML_APP_VAL"],
    "did_bound": os.environ["DID_BOUND_VAL"] == "true",
    "codec": os.environ["CODEC_VAL"],
    "codec_ok": os.environ["CODEC_OK_VAL"] == "true",
    "voice_method": os.environ["VOICE_METHOD_VAL"],
    "status_callback": os.environ["STATUS_CB_VAL"],
    "status_callback_ok": os.environ["STATUS_CB_OK_VAL"] == "true",
    "status_callback_method": os.environ["STATUS_CB_METHOD_VAL"],
    "status_callback_method_ok": os.environ["STATUS_CB_METHOD_OK_VAL"] == "true",
    "verified_at": os.environ["NOW_ISO_VAL"],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

echo "[INFO] wrote $OUT_PATH"

if [ "$STATUS_CB_OK" != "true" ]; then
  exit 1
fi

exit 0
