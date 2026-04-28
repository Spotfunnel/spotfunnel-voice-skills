#!/bin/bash
# scripts/bulk-create-texml-apps.sh
#
# One-shot setup: for every DID in the operator's Telnyx account that isn't
# already bound to a TeXML application, create a per-DID TeXML app with the
# correct codec / voice_url placeholder / status_callback config, bind the
# DID to its new app, and tag both with `pool-available`.
#
# After this script runs, the operator never manages TeXML app IDs by hand
# again — `telnyx-claim-did.sh` discovers pool-available apps via tags at
# claim time.
#
# Idempotent: re-running is safe. DIDs already bound to a TeXML app are
# skipped with a `[SKIP]` line.
#
# Args:
#   --dids <e164-list>          (optional) comma-separated list of E.164
#                                 numbers to operate on. If omitted, the
#                                 script processes every DID in the account
#                                 that has no connection_id set.
#   --telnyx-status-callback-url <url>
#                                (optional) explicit Telnyx TeXML
#                                 status_callback URL. If omitted, no
#                                 status_callback is set on the TeXML app.
#                                 NOTE: this is for Telnyx call-lifecycle
#                                 events only — distinct from the Ultravox
#                                 `call.ended` webhook, which is set on each
#                                 agent in the Ultravox console (see
#                                 /onboard-customer Stage 7) and points at
#                                 dashboard-server's /webhooks/call-ended.
#                                 Reusing the same URL for both was a real
#                                 bug — they're different services.
#   --dry-run                    (flag) show what would be created without
#                                 making any Telnyx mutations.
#   --help                       print usage.
#
# Env:
#   TELNYX_API_KEY               required.
#   TELNYX_STATUS_CALLBACK_URL   optional. Same effect as
#                                 --telnyx-status-callback-url. Leave unset
#                                 if you don't need Telnyx call-lifecycle
#                                 callbacks (rough /base-agent agents
#                                 don't — warm-transfer is wired separately
#                                 if/when it ships).
#
# Exit codes:
#   0   all DIDs processed (or skipped) successfully.
#   1   any DID failed to create/bind, or required args/env missing.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/bulk-create-texml-apps.sh \
    [--dids <+E.164,+E.164,...>] \
    [--dashboard-server-url <url>] \
    [--dry-run]

For every DID in your Telnyx account without a TeXML app bound, creates a
TeXML app, binds the DID to it, and tags everything `pool-available`.
Idempotent — DIDs already bound are skipped.
EOF
}

DIDS_FILTER=""
STATUS_CB_OVERRIDE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dids)
      DIDS_FILTER="${2:-}"
      shift 2
      ;;
    --telnyx-status-callback-url)
      STATUS_CB_OVERRIDE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

if [ -z "${TELNYX_API_KEY:-}" ]; then
  echo "[ERR] TELNYX_API_KEY is empty" >&2
  exit 1
fi

# Telnyx call-lifecycle status_callback. Distinct from the Ultravox
# `call.ended` webhook (which is set on each agent in the Ultravox console
# and points at dashboard-server). Empty by default — rough /base-agent
# agents don't need Telnyx-side call-lifecycle callbacks.
STATUS_CALLBACK_URL="${STATUS_CB_OVERRIDE:-${TELNYX_STATUS_CALLBACK_URL:-}}"
STATUS_CALLBACK_URL="${STATUS_CALLBACK_URL%/}"
VOICE_URL_PLACEHOLDER="https://app.ultravox.ai/api/agents/PLACEHOLDER/telephony_xml"

if [ "$DRY_RUN" = "1" ]; then
  echo "[INFO] DRY RUN — no Telnyx mutations will be made"
fi
if [ -n "$STATUS_CALLBACK_URL" ]; then
  echo "[INFO] status_callback_url = $STATUS_CALLBACK_URL"
else
  echo "[INFO] status_callback_url = <omitted> (no Telnyx call-lifecycle callbacks)"
fi
echo "[INFO] voice_url placeholder = $VOICE_URL_PLACEHOLDER"

# ----- Step 1: list every DID in the account -----
LIST_RESP="$(mktemp)"
trap 'rm -f "$LIST_RESP"' EXIT

echo "[INFO] listing DIDs in Telnyx account"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$LIST_RESP" -w "%{http_code}" \
  -G "https://api.telnyx.com/v2/phone_numbers" \
  --data-urlencode "page[size]=250" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET phone_numbers returned HTTP $HTTP_CODE" >&2
  cat "$LIST_RESP" >&2
  echo >&2
  exit 1
fi

# Build the candidate list as TSV: phone_number<TAB>id<TAB>connection_id<TAB>tags_csv
CANDIDATES_FILE="$(mktemp)"
trap 'rm -f "$LIST_RESP" "$CANDIDATES_FILE"' EXIT

DIDS_FILTER_IN="$DIDS_FILTER" \
python3 - "$LIST_RESP" "$CANDIDATES_FILE" <<'PY'
import json, os, sys
resp_path, out_path = sys.argv[1], sys.argv[2]
with open(resp_path, "r", encoding="utf-8") as f:
    body = json.load(f)

raw_filter = (os.environ.get("DIDS_FILTER_IN") or "").strip()
filter_set = None
if raw_filter:
    filter_set = {s.strip() for s in raw_filter.split(",") if s.strip()}

rows = []
for n in body.get("data") or []:
    pn   = n.get("phone_number") or ""
    pid  = n.get("id") or ""
    conn = n.get("connection_id") or ""
    tags = n.get("tags") or []
    tags_csv = ",".join(str(t) for t in tags if t)
    if filter_set is not None and pn not in filter_set:
        continue
    rows.append("\t".join([pn, str(pid), str(conn), tags_csv]))

# newline="" suppresses Windows' \n -> \r\n translation. Without it, the
# bash `read` loop downstream sees a stray \r as the content of the last
# tab-separated field, which made the CURRENT_CONN check spuriously skip
# every DID with an empty connection_id (the very ones we want to bind).
with open(out_path, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(rows))
    if rows:
        f.write("\n")
PY

TOTAL_LINES="$(wc -l < "$CANDIDATES_FILE" | tr -d ' ')"
if [ "$TOTAL_LINES" = "0" ] || [ -z "$TOTAL_LINES" ]; then
  if [ -n "$DIDS_FILTER" ]; then
    echo "[ERR] none of the DIDs in --dids matched any number in your Telnyx account" >&2
    exit 1
  fi
  echo "[INFO] no DIDs found in account — buy some in the Telnyx console first"
  exit 0
fi

echo "[INFO] $TOTAL_LINES DID(s) in scope"

# ----- Step 2: walk each candidate, create + bind as needed -----
PROCESSED=0
SKIPPED=0
FAILED=0

while IFS=$'\t' read -r DID PN_ID CURRENT_CONN TAGS_CSV; do
  [ -z "$DID" ] && continue

  if [ -n "$CURRENT_CONN" ]; then
    echo "[SKIP] $DID already bound to connection_id=$CURRENT_CONN"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Normalize for friendly_name: strip leading +.
  NORMALIZED="${DID#+}"
  FRIENDLY_NAME="pool-did-${NORMALIZED}"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[OK] (dry-run) would create TeXML app '$FRIENDLY_NAME' and bind DID $DID (pool-available)"
    PROCESSED=$((PROCESSED + 1))
    continue
  fi

  # Build the TeXML app payload. status_callback is omitted entirely when
  # STATUS_CALLBACK_URL is empty — Telnyx accepts a TeXML app without one
  # and simply doesn't fire call-lifecycle callbacks.
  CREATE_PAYLOAD="$(FRIENDLY_NAME="$FRIENDLY_NAME" \
                    VOICE_URL="$VOICE_URL_PLACEHOLDER" \
                    STATUS_CB_URL="$STATUS_CALLBACK_URL" \
                    python3 - <<'PY'
import json, os
payload = {
    "friendly_name": os.environ["FRIENDLY_NAME"],
    "voice_url": os.environ["VOICE_URL"],
    "voice_method": "POST",
    "anchorsite_override": "Latency",
    "inbound": {
        "codecs": ["OPUS", "G711U"],
    },
    "tags": ["pool-available"],
}
status_cb = os.environ.get("STATUS_CB_URL", "").strip()
if status_cb:
    payload["status_callback"] = status_cb
    payload["status_callback_method"] = "POST"
print(json.dumps(payload))
PY
)"

  CREATE_RESP="$(mktemp)"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$CREATE_RESP" -w "%{http_code}" \
    -X POST "https://api.telnyx.com/v2/texml_applications" \
    -H "Authorization: Bearer $TELNYX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$CREATE_PAYLOAD")"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "[ERR] $DID — POST texml_applications returned HTTP $HTTP_CODE"
    cat "$CREATE_RESP"
    echo
    rm -f "$CREATE_RESP"
    FAILED=$((FAILED + 1))
    continue
  fi

  NEW_APP_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("data") or {}).get("id") or "")' "$CREATE_RESP")"
  rm -f "$CREATE_RESP"

  if [ -z "$NEW_APP_ID" ]; then
    echo "[ERR] $DID — TeXML app create returned 2xx but no id"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Bind the DID to the new app + tag it.
  PATCH_PAYLOAD="$(NEW_APP_ID="$NEW_APP_ID" python3 - <<'PY'
import json, os
print(json.dumps({
    "connection_id": os.environ["NEW_APP_ID"],
    "tags": ["pool-available"],
}))
PY
)"

  PATCH_RESP="$(mktemp)"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$PATCH_RESP" -w "%{http_code}" \
    -X PATCH "https://api.telnyx.com/v2/phone_numbers/$PN_ID" \
    -H "Authorization: Bearer $TELNYX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PATCH_PAYLOAD")"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "[ERR] $DID — PATCH phone_number returned HTTP $HTTP_CODE (app $NEW_APP_ID was created but DID not bound — clean up manually)"
    cat "$PATCH_RESP"
    echo
    rm -f "$PATCH_RESP"
    FAILED=$((FAILED + 1))
    continue
  fi
  rm -f "$PATCH_RESP"

  echo "[OK] $DID -> app $NEW_APP_ID (pool-available)"
  PROCESSED=$((PROCESSED + 1))

done < "$CANDIDATES_FILE"

echo
echo "[INFO] summary: processed=$PROCESSED skipped=$SKIPPED failed=$FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
