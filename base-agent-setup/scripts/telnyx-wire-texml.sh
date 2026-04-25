#!/bin/bash
# scripts/telnyx-wire-texml.sh
#
# Verify (and where appropriate, repair) that a claimed DID is correctly
# bound to the operator's pool TeXML app, and that the pool TeXML app
# itself has the right codec + a non-empty status_callback URL.
#
# Mirrors VAM's `claim_did_for_user` post-claim invariants. VAM PATCHes
# voice_url + status_callback on the TeXML app on every repoint; this
# script enforces the DID-side bind and audits the TeXML-side settings
# without overwriting them blindly (codec changes are pool-wide and
# therefore an ops decision, not per-customer).
#
# Args:
#   --did <+E.164>              required.
#   --texml-app-id <id>         optional, defaults to $TELNYX_POOL_TEXML_APP_ID.
#   --out <dir>                 required.
#   --help                      print usage.
#
# Env:
#   TELNYX_API_KEY              required.
#   TELNYX_POOL_TEXML_APP_ID    required when --texml-app-id is omitted.
#
# Behavior:
#   1. GET phone_number — confirm voice.connection_id == TeXML app id.
#      If not, PATCH the DID's voice connection to the TeXML app.
#   2. GET texml_application — confirm codec is set (16 kHz preferred;
#      g711 acceptable). Mismatch = WARN only (codec is pool-wide).
#   3. Confirm status_callback is a non-empty URL. Missing = FAIL with
#      diagnostic (the operator's webhook URL is mandatory for our
#      warm-transfer + lifecycle wiring).
#
# Writes <out>/texml-wired.json. Exit 1 on any non-recoverable failure.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/telnyx-wire-texml.sh \
    --did <+E.164> \
    [--texml-app-id <id>] \
    --out <dir>

Verifies the DID is bound to the pool TeXML app, audits the TeXML app's
codec + status_callback, and writes texml-wired.json with results.
EOF
}

DID=""
TEXML_APP_ID=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --did)
      DID="${2:-}"
      shift 2
      ;;
    --texml-app-id)
      TEXML_APP_ID="${2:-}"
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

if [ -z "$TEXML_APP_ID" ]; then
  TEXML_APP_ID="$TELNYX_POOL_TEXML_APP_ID"
fi
if [ -z "$TEXML_APP_ID" ]; then
  echo "[ERR] no --texml-app-id and TELNYX_POOL_TEXML_APP_ID is empty" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

# ----- Step 1: GET phone_number, find by E.164 -----
PN_RESP="$(mktemp)"
APP_RESP="$(mktemp)"
PATCH_RESP="$(mktemp)"
trap 'rm -f "$PN_RESP" "$APP_RESP" "$PATCH_RESP"' EXIT

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

DID_BOUND="false"
if [ "$CURRENT_CONN" = "$TEXML_APP_ID" ]; then
  DID_BOUND="true"
  echo "[OK] DID $DID already bound to TeXML app $TEXML_APP_ID"
else
  echo "[WARN] DID $DID has connection_id=$CURRENT_CONN, expected $TEXML_APP_ID — patching"
  PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"connection_id": sys.argv[1]}))' "$TEXML_APP_ID")"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$PATCH_RESP" -w "%{http_code}" \
    -X PATCH "https://api.telnyx.com/v2/phone_numbers/$PN_ID" \
    -H "Authorization: Bearer $TELNYX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "[ERR] Telnyx PATCH phone_number returned HTTP $HTTP_CODE" >&2
    cat "$PATCH_RESP" >&2
    echo >&2
    exit 1
  fi
  DID_BOUND="true"
  echo "[OK] DID $DID re-bound to TeXML app $TEXML_APP_ID"
fi

# ----- Step 2 + 3: GET TeXML app, audit codec + status_callback -----
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

# Extract codec + status_callback. Telnyx's TeXML app schema exposes
# `inbound.channel_limit`, `inbound.codecs` (list), and root-level
# `status_callback`. Fall back across known field name variants.
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

# Status-callback location varies between Telnyx schema versions. Try the
# obvious places. We treat ANY non-empty URL as acceptable — the operator
# controls the URL, we just demand it be set.
status_cb = (
    data.get("status_callback")
    or data.get("statusCallback")
    or ""
)

# Codec OK heuristic: PCM 16k preferred; G711 fallback acceptable. The
# pool ships with these by default in VAM. Anything else = warn.
known_ok = {"PCMU", "PCMA", "G722", "OPUS", "L16", "G711U", "G711A"}
codec_ok = False
if codecs:
    codec_ok = any(c.upper() in known_ok or c.upper().startswith("G711") or c.upper().startswith("L16") for c in codecs)

print(f"{codec_str}|||{int(codec_ok)}|||{status_cb}")
PY
)"

CODEC="${APP_INFO%%|||*}"
REST="${APP_INFO#*|||}"
CODEC_OK_INT="${REST%%|||*}"
STATUS_CB="${REST#*|||}"

CODEC_OK="false"
if [ "$CODEC_OK_INT" = "1" ]; then
  CODEC_OK="true"
fi

if [ "$CODEC_OK" = "true" ]; then
  echo "[OK] codec(s)=[$CODEC]"
else
  echo "[WARN] codec(s)=[$CODEC] not in known-good set — pool-wide config, treat as ops decision"
fi

# Status callback validation: must be non-empty AND look like an http(s) URL.
STATUS_CB_OK="false"
case "$STATUS_CB" in
  http://*|https://*) STATUS_CB_OK="true" ;;
  *) STATUS_CB_OK="false" ;;
esac

if [ "$STATUS_CB_OK" = "true" ]; then
  echo "[OK] status_callback is set: $STATUS_CB"
else
  echo "[ERR] TeXML app $TEXML_APP_ID has no status_callback URL (or it's malformed: '$STATUS_CB')" >&2
  echo "[ERR] Set status_callback on the TeXML app in your Telnyx console — required for call lifecycle webhooks" >&2
fi

# ----- Write texml-wired.json -----
OUT_PATH="$OUT_DIR/texml-wired.json"

DID_VAL="$DID" \
DID_BOUND_VAL="$DID_BOUND" \
CODEC_VAL="$CODEC" \
CODEC_OK_VAL="$CODEC_OK" \
STATUS_CB_VAL="$STATUS_CB" \
STATUS_CB_OK_VAL="$STATUS_CB_OK" \
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
    "status_callback": os.environ["STATUS_CB_VAL"],
    "status_callback_ok": os.environ["STATUS_CB_OK_VAL"] == "true",
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
