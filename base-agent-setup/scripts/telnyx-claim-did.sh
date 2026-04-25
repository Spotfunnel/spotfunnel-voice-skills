#!/bin/bash
# scripts/telnyx-claim-did.sh
#
# Pick an unassigned DID from the operator's Telnyx pool for use by the
# /base-agent customer onboarding flow.
#
# Pool model (one TeXML app per DID, always):
#   - The operator runs `bulk-create-texml-apps.sh` once at setup. That
#     script creates one TeXML app per DID, binds the DID to its app, and
#     tags both with `pool-available`.
#   - This script lists every TeXML app in the account, filters to apps
#     tagged `pool-available` AND not yet tagged `claimed-*`, and picks
#     one (preferring the customer's area code if requested).
#   - The picked app's tags are updated to add `claimed-<customer-slug>`
#     while keeping `pool-available` for auditability.
#
# Args:
#   --area-code <code>          (optional) AU area code without +61: 02, 03,
#                                 04, 07, 08, 13. Empty = any unassigned AU
#                                 number. For non-AU operators this is
#                                 country-specific — substitute your local
#                                 numbering plan.
#   --strict-area-code          (optional flag) abort if no DID matches the
#                                 area code instead of falling back.
#   --customer-slug <slug>      (optional) added as a `claimed-<slug>` tag
#                                 on the picked TeXML app. Defaults to the
#                                 ISO timestamp if omitted.
#   --dry-run                   (optional flag) identify the DID that WOULD
#                                 be claimed, write JSON with "dry_run":
#                                 true, but make no Telnyx mutations.
#   --out <dir>                 (required) directory for claimed-did.json.
#   --help                      print usage.
#
# Env:
#   TELNYX_API_KEY              required.
#   TELNYX_TEST_POOL_EMPTY=1    optional — short-circuit to the empty-pool
#                                 path WITHOUT calling Telnyx. For smoke
#                                 tests of the alert path.
#
# Exit codes:
#   0   DID picked (or dry-run picked).
#   1   pool exhausted, --strict-area-code mismatch, missing args, or any
#         Telnyx API error.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/telnyx-claim-did.sh \
    [--area-code <code>] \
    [--strict-area-code] \
    [--customer-slug <slug>] \
    [--dry-run] \
    --out <dir>

Picks one unassigned DID from the operator's Telnyx pool and writes it to
<out>/claimed-did.json. Pool members are TeXML apps tagged `pool-available`
and not yet tagged `claimed-*`. Sends a Resend pool-low alert when remaining
< 3, and a CRIT alert + exit 1 when the pool is exhausted.

Args:
  --area-code <code>      AU area code without +61 (02, 03, 04, 07, 08, 13).
                          Empty/omitted = any AU number.
  --strict-area-code      Abort instead of falling back when area code
                          can't be matched.
  --customer-slug <slug>  Tag value used for `claimed-<slug>`. Defaults to
                          the ISO timestamp.
  --dry-run               Identify the DID without claiming. Pool-low/empty
                          alerts still fire so smoke tests are realistic.
  --out <dir>             Where to write claimed-did.json.
EOF
}

AREA_CODE=""
STRICT_AREA=0
DRY_RUN=0
OUT_DIR=""
CUSTOMER_SLUG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --area-code)
      AREA_CODE="${2:-}"
      shift 2
      ;;
    --strict-area-code)
      STRICT_AREA=1
      shift
      ;;
    --customer-slug)
      CUSTOMER_SLUG="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

mkdir -p "$OUT_DIR"

NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"

if [ -z "$CUSTOMER_SLUG" ]; then
  # Fall back to a timestamp-based slug so the tag is still unique.
  CUSTOMER_SLUG="$(python3 -c 'from datetime import datetime, timezone; print("ts-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))')"
fi

# ----- Test-mode: simulate empty pool without calling Telnyx -----
if [ "${TELNYX_TEST_POOL_EMPTY:-0}" = "1" ]; then
  echo "[INFO] TELNYX_TEST_POOL_EMPTY=1 set — simulating empty-pool path"
  bash "$SCRIPT_DIR/resend-alert.sh" \
    --severity crit \
    --subject "[VoiceAIMachine] DID pool exhausted" \
    --body "Zero TeXML apps tagged pool-available (and not yet claimed) found in your Telnyx account. Buy more DIDs and re-run bulk-create-texml-apps.sh, then retry /base-agent. (Simulated via TELNYX_TEST_POOL_EMPTY=1.)" \
    >/dev/null || true
  echo "[ERR] pool exhausted — buy more DIDs in your Telnyx account and re-run" >&2
  exit 1
fi

# ----- Step 1: list every TeXML app in the account -----
APPS_RESP="$(mktemp)"
trap 'rm -f "$APPS_RESP"' EXIT

echo "[INFO] listing TeXML apps in Telnyx account"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$APPS_RESP" -w "%{http_code}" \
  -G "https://api.telnyx.com/v2/texml_applications" \
  --data-urlencode "page[size]=100" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET texml_applications returned HTTP $HTTP_CODE" >&2
  cat "$APPS_RESP" >&2
  echo >&2
  exit 1
fi

# ----- Step 2: list every DID so we can map app -> bound DID -----
NUMS_RESP="$(mktemp)"
trap 'rm -f "$APPS_RESP" "$NUMS_RESP"' EXIT

echo "[INFO] listing DIDs in Telnyx account (for app -> DID mapping)"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$NUMS_RESP" -w "%{http_code}" \
  -G "https://api.telnyx.com/v2/phone_numbers" \
  --data-urlencode "page[size]=250" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET phone_numbers returned HTTP $HTTP_CODE" >&2
  cat "$NUMS_RESP" >&2
  echo >&2
  exit 1
fi

# ----- Step 3: filter, classify, and pick -----
PICK_FILE="$(mktemp)"
trap 'rm -f "$APPS_RESP" "$NUMS_RESP" "$PICK_FILE"' EXIT

AREA_CODE_IN="$AREA_CODE" \
STRICT_AREA_IN="$STRICT_AREA" \
python3 - "$APPS_RESP" "$NUMS_RESP" "$PICK_FILE" <<'PY'
import json, os, sys

apps_path, nums_path, pick_path = sys.argv[1], sys.argv[2], sys.argv[3]
area_in = os.environ.get("AREA_CODE_IN", "").strip()
strict  = os.environ.get("STRICT_AREA_IN", "0") == "1"

with open(apps_path, "r", encoding="utf-8") as f:
    apps_body = json.load(f)
with open(nums_path, "r", encoding="utf-8") as f:
    nums_body = json.load(f)

apps = apps_body.get("data") or []
nums = nums_body.get("data") or []

# Build app_id -> bound phone_number map (one app per DID is the model).
app_to_did = {}
for n in nums:
    conn = str(n.get("connection_id") or "")
    if conn and conn not in app_to_did:
        app_to_did[conn] = n.get("phone_number") or ""

def has_tag(app, prefix):
    for t in app.get("tags") or []:
        if isinstance(t, str) and t.startswith(prefix):
            return True
    return False

def is_pool_available(app):
    tags = app.get("tags") or []
    pool_avail = any(isinstance(t, str) and t == "pool-available" for t in tags)
    if not pool_avail:
        return False
    if has_tag(app, "claimed-"):
        return False
    return True

available = [a for a in apps if is_pool_available(a)]

# Area code filter via the bound DID.
def extract_au_area(e164):
    if not e164.startswith("+61"):
        return None
    rest = e164[3:]
    if rest.startswith("13"):
        return "13"
    if len(rest) >= 1:
        return "0" + rest[0]
    return None

def app_area(app):
    did = app_to_did.get(str(app.get("id") or ""), "")
    return extract_au_area(did or "")

if area_in:
    matched = [a for a in available if app_area(a) == area_in]
else:
    matched = list(available)

fallback_used = False
if area_in and not matched:
    if strict:
        out = {
            "status": "no_area_code_match_strict",
            "area_code_requested": area_in,
            "pool_remaining": len(available),
        }
        with open(pick_path, "w", encoding="utf-8") as f:
            json.dump(out, f)
        sys.exit(0)
    matched = list(available)
    fallback_used = True

if not matched:
    out = {
        "status": "empty",
        "area_code_requested": area_in,
        "pool_remaining": 0,
    }
    with open(pick_path, "w", encoding="utf-8") as f:
        json.dump(out, f)
    sys.exit(0)

picked = matched[0]
remaining_after = max(0, len(available) - 1)
picked_did = app_to_did.get(str(picked.get("id") or ""), "")
picked_area = extract_au_area(picked_did or "") or ""

out = {
    "status": "ok",
    "did": picked_did,
    "texml_app_id": str(picked.get("id") or ""),
    "current_tags": picked.get("tags") or [],
    "area_code": picked_area,
    "area_code_requested": area_in,
    "fallback_used": fallback_used,
    "pool_remaining": remaining_after,
    "pool_total_unassigned": len(available),
}
with open(pick_path, "w", encoding="utf-8") as f:
    json.dump(out, f)
PY

PICK_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$PICK_FILE")"

if [ "$PICK_STATUS" = "no_area_code_match_strict" ]; then
  REMAINING="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pool_remaining"])' "$PICK_FILE")"
  echo "[ERR] --strict-area-code: no DID in pool matches area code '$AREA_CODE' ($REMAINING unassigned in pool overall)" >&2
  exit 1
fi

if [ "$PICK_STATUS" = "empty" ]; then
  echo "[ERR] pool exhausted — buy more DIDs in your Telnyx account and re-run" >&2
  bash "$SCRIPT_DIR/resend-alert.sh" \
    --severity crit \
    --subject "[VoiceAIMachine] DID pool exhausted" \
    --body "Zero TeXML apps tagged pool-available (and not yet claimed) found in your Telnyx account. Buy more DIDs in your Telnyx console, run bulk-create-texml-apps.sh to wire them, then re-run /base-agent." \
    >/dev/null || true
  exit 1
fi

DID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["did"])' "$PICK_FILE")"
APP_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["texml_app_id"])' "$PICK_FILE")"
PICKED_AREA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["area_code"])' "$PICK_FILE")"
FALLBACK_USED="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["fallback_used"]).lower())' "$PICK_FILE")"
REMAINING_AFTER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pool_remaining"])' "$PICK_FILE")"

if [ "$FALLBACK_USED" = "true" ]; then
  echo "[WARN] no DID matched area code '$AREA_CODE' — falling back to any unassigned DID in the pool"
fi

# ----- Step 4: tag the picked TeXML app `claimed-<slug>` (unless --dry-run) -----
if [ "$DRY_RUN" != "1" ]; then
  CURRENT_TAGS_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["current_tags"]))' "$PICK_FILE")"
  NEW_TAGS_PAYLOAD="$(CUR_TAGS="$CURRENT_TAGS_JSON" SLUG="$CUSTOMER_SLUG" python3 - <<'PY'
import json, os
cur = json.loads(os.environ["CUR_TAGS"])
slug = os.environ["SLUG"]
new_tags = list(cur)
claim_tag = f"claimed-{slug}"
if claim_tag not in new_tags:
    new_tags.append(claim_tag)
print(json.dumps({"tags": new_tags}))
PY
)"

  TAG_RESP="$(mktemp)"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$TAG_RESP" -w "%{http_code}" \
    -X PATCH "https://api.telnyx.com/v2/texml_applications/$APP_ID" \
    -H "Authorization: Bearer $TELNYX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$NEW_TAGS_PAYLOAD")"
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "[ERR] Telnyx PATCH texml_applications returned HTTP $HTTP_CODE while tagging claim" >&2
    cat "$TAG_RESP" >&2
    echo >&2
    rm -f "$TAG_RESP"
    exit 1
  fi
  rm -f "$TAG_RESP"
fi

# ----- Pool-low alert -----
if [ "$REMAINING_AFTER" -lt 3 ]; then
  echo "[WARN] pool remaining after this pick = $REMAINING_AFTER — firing pool-low alert"
  bash "$SCRIPT_DIR/resend-alert.sh" \
    --severity warn \
    --subject "[VoiceAIMachine] DID pool low — $REMAINING_AFTER remaining" \
    --body "After this claim only $REMAINING_AFTER pool-available TeXML app(s) remain. Buy more DIDs in your Telnyx console and run bulk-create-texml-apps.sh before the next /base-agent run." \
    >/dev/null || true
fi

# ----- Write claimed-did.json -----
OUT_PATH="$OUT_DIR/claimed-did.json"

DRY_RUN_FLAG="$DRY_RUN" \
NOW_ISO="$NOW_ISO" \
DID="$DID" \
APP_ID="$APP_ID" \
SLUG_VAL="$CUSTOMER_SLUG" \
AREA_CODE_PICKED="$PICKED_AREA" \
AREA_CODE_REQ="$AREA_CODE" \
FALLBACK_USED_FLAG="$FALLBACK_USED" \
REMAINING_AFTER_VAL="$REMAINING_AFTER" \
python3 - "$OUT_PATH" <<'PY'
import json, os, sys
out_path = sys.argv[1]
payload = {
    "did": os.environ["DID"],
    "texml_app_id": os.environ["APP_ID"],
    "claimed_slug": os.environ["SLUG_VAL"],
    "area_code": os.environ["AREA_CODE_PICKED"],
    "area_code_requested": os.environ["AREA_CODE_REQ"],
    "fallback_used": os.environ["FALLBACK_USED_FLAG"] == "true",
    "pool_remaining": int(os.environ["REMAINING_AFTER_VAL"]),
    "claimed_at": os.environ["NOW_ISO"],
}
if os.environ["DRY_RUN_FLAG"] == "1":
    payload["dry_run"] = True
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

if [ "$DRY_RUN" = "1" ]; then
  echo "[OK] dry-run: would claim $DID via app $APP_ID (area=$PICKED_AREA, remaining_after=$REMAINING_AFTER)"
else
  echo "[OK] picked $DID via app $APP_ID (area=$PICKED_AREA, remaining_after=$REMAINING_AFTER, claimed-$CUSTOMER_SLUG)"
fi
echo "[INFO] wrote $OUT_PATH"
exit 0
