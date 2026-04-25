#!/bin/bash
# scripts/telnyx-claim-did.sh
#
# Pick an unassigned DID from the operator's Telnyx pool for use by the
# /base-agent customer onboarding flow.
#
# Mirrors the *intent* of VAM's `claim_did_for_user` (services/api/src/api/
# routes/assign_number.py) but Telnyx-side rather than Supabase-side, since
# the portable skill has no `phone_number_pool` table to query.
#
# Pool model:
#   - The operator pre-buys DIDs in Telnyx and binds each one to the pool
#     TeXML app ($TELNYX_POOL_TEXML_APP_ID) via the DID's voice connection.
#   - "Unassigned" means the DID is bound to the pool TeXML app AND its
#     TeXML app's voice_url is empty (or still points at the operator's
#     placeholder). Once `wire-ultravox-telephony.sh` (Task 15) sets a
#     voice_url, the DID is considered claimed.
#   - This script does NOT mutate the DID — the actual claim happens when
#     telnyx-wire-texml.sh + wire-ultravox-telephony.sh run. The script
#     just picks one and writes it to the run-state JSON.
#
# Args:
#   --area-code <code>          (optional) AU area code without +61: 02, 03,
#                                 04, 07, 08, 13. Empty = any unassigned AU
#                                 number. For non-AU operators this is
#                                 country-specific — substitute your local
#                                 numbering plan.
#   --strict-area-code          (optional flag) abort if no DID matches the
#                                 area code instead of falling back.
#   --dry-run                   (optional flag) identify the DID that WOULD
#                                 be claimed, write JSON with "dry_run":
#                                 true, but make no Telnyx mutations.
#   --out <dir>                 (required) directory for claimed-did.json.
#   --help                      print usage.
#
# Env:
#   TELNYX_API_KEY              required.
#   TELNYX_POOL_TEXML_APP_ID    required — the TeXML app ID DIDs are bound
#                                 to while sitting in the pool.
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
    [--dry-run] \
    --out <dir>

Picks one unassigned DID from the operator's Telnyx pool and writes it to
<out>/claimed-did.json. Sends a Resend pool-low alert when remaining < 3,
and a CRIT alert + exit 1 when the pool is exhausted.

Args:
  --area-code <code>      AU area code without +61 (02, 03, 04, 07, 08, 13).
                          Empty/omitted = any AU number.
  --strict-area-code      Abort instead of falling back when area code
                          can't be matched.
  --dry-run               Identify the DID without claiming. Pool-low/empty
                          alerts still fire so smoke tests are realistic.
  --out <dir>             Where to write claimed-did.json.
EOF
}

AREA_CODE=""
STRICT_AREA=0
DRY_RUN=0
OUT_DIR=""

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

# ----- Test-mode: simulate empty pool without calling Telnyx -----
if [ "${TELNYX_TEST_POOL_EMPTY:-0}" = "1" ]; then
  echo "[INFO] TELNYX_TEST_POOL_EMPTY=1 set — simulating empty-pool path"
  bash "$SCRIPT_DIR/resend-alert.sh" \
    --severity crit \
    --subject "[VoiceAIMachine] DID pool exhausted" \
    --body "The Telnyx pool tied to TeXML app $TELNYX_POOL_TEXML_APP_ID has zero unassigned DIDs. Buy more DIDs in your Telnyx console and re-run /base-agent. (Simulated via TELNYX_TEST_POOL_EMPTY=1.)" \
    >/dev/null || true
  echo "[ERR] pool exhausted — buy more DIDs in your Telnyx account and re-run" >&2
  exit 1
fi

# ----- Fetch DIDs bound to the pool TeXML app -----
RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

# Telnyx phone_numbers list. Filter by voice_connection / TeXML application
# server-side via filter[voice.connection_id]. Page size 250 covers most
# operator pools comfortably; if you exceed, paginate.
echo "[INFO] listing DIDs bound to TeXML app $TELNYX_POOL_TEXML_APP_ID"
HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$RESP_FILE" -w "%{http_code}" \
  -G "https://api.telnyx.com/v2/phone_numbers" \
  --data-urlencode "filter[connection_id]=$TELNYX_POOL_TEXML_APP_ID" \
  --data-urlencode "page[size]=250" \
  -H "Authorization: Bearer $TELNYX_API_KEY")"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "[ERR] Telnyx GET phone_numbers returned HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  echo >&2
  exit 1
fi

# ----- Filter, classify, and pick a DID -----
PICK_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE" "$PICK_FILE"' EXIT

POOL_TEXML_APP_ID="$TELNYX_POOL_TEXML_APP_ID" \
TELNYX_API_KEY="$TELNYX_API_KEY" \
AREA_CODE_IN="$AREA_CODE" \
STRICT_AREA_IN="$STRICT_AREA" \
python3 - "$RESP_FILE" "$PICK_FILE" <<'PY'
import json, os, sys, urllib.request, urllib.parse, urllib.error

resp_path, pick_path = sys.argv[1], sys.argv[2]
pool_app = os.environ["POOL_TEXML_APP_ID"]
api_key  = os.environ["TELNYX_API_KEY"]
area_in  = os.environ.get("AREA_CODE_IN", "").strip()
strict   = os.environ.get("STRICT_AREA_IN", "0") == "1"

with open(resp_path, "r", encoding="utf-8") as f:
    body = json.load(f)

dids = body.get("data") or []

# Keep only DIDs whose connection_id matches the pool TeXML app.
# (Telnyx's filter param is best-effort; double-check client-side.)
pool_dids = []
for n in dids:
    conn = n.get("connection_id") or ""
    if str(conn) == str(pool_app):
        pool_dids.append(n)

# A DID is "unassigned" if its TeXML app's voice_url is empty/placeholder.
# Fetch each candidate's TeXML app voice_url. The pool TeXML app is shared
# across the pool, so all DIDs in the pool share the same voice_url at
# rest — meaning under the strict shared-app reading they're either all
# assigned or all unassigned. The VAM model has each DID owning its own
# TeXML app row in phone_number_pool with its own texml_app_id. Without a
# Supabase pool to consult, we infer "unassigned" by reading the
# phone_number's own voice settings tags / "tags" metadata: convention is
# that a DID gets a "claimed:<user>" tag once wired, so anything without
# such a tag is available.
def has_claim_tag(n):
    tags = n.get("tags") or []
    for t in tags:
        if isinstance(t, str) and t.startswith("claimed:"):
            return True
    return False

unassigned = [n for n in pool_dids if not has_claim_tag(n)]

# Area code filter. Telnyx returns E.164 in `phone_number` field, e.g.
# "+61731304231". For AU, area code lives at chars [3:5] (e.g. "07").
def extract_au_area(e164):
    # +61 + area_code + rest. Treat 13xx as the special "13" services code.
    if not e164.startswith("+61"):
        return None
    rest = e164[3:]
    if rest.startswith("13"):
        return "13"
    if len(rest) >= 1:
        return "0" + rest[0]
    return None

if area_in:
    matched = [n for n in unassigned if extract_au_area(n.get("phone_number","")) == area_in]
else:
    matched = list(unassigned)

fallback_used = False
if area_in and not matched:
    if strict:
        out = {
            "status": "no_area_code_match_strict",
            "area_code_requested": area_in,
            "pool_remaining": len(unassigned),
        }
        with open(pick_path, "w", encoding="utf-8") as f:
            json.dump(out, f)
        sys.exit(0)
    matched = list(unassigned)
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
remaining_after = max(0, len(unassigned) - 1)
picked_area = extract_au_area(picked.get("phone_number","")) or ""

out = {
    "status": "ok",
    "did": picked.get("phone_number"),
    "phone_number_id": picked.get("id"),
    "connection_id": picked.get("connection_id"),
    "area_code": picked_area,
    "area_code_requested": area_in,
    "fallback_used": fallback_used,
    "pool_remaining": remaining_after,
    "pool_total_unassigned": len(unassigned),
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
    --body "The Telnyx pool tied to TeXML app $TELNYX_POOL_TEXML_APP_ID has zero unassigned DIDs. Buy more numbers in your Telnyx console and re-run /base-agent." \
    >/dev/null || true
  exit 1
fi

DID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["did"])' "$PICK_FILE")"
PICKED_AREA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["area_code"])' "$PICK_FILE")"
FALLBACK_USED="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["fallback_used"]).lower())' "$PICK_FILE")"
REMAINING_AFTER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pool_remaining"])' "$PICK_FILE")"

if [ "$FALLBACK_USED" = "true" ]; then
  echo "[WARN] no DID matched area code '$AREA_CODE' — falling back to any unassigned DID in the pool"
fi

# ----- Pool-low alert -----
if [ "$REMAINING_AFTER" -lt 3 ]; then
  echo "[WARN] pool remaining after this pick = $REMAINING_AFTER — firing pool-low alert"
  bash "$SCRIPT_DIR/resend-alert.sh" \
    --severity warn \
    --subject "[VoiceAIMachine] DID pool low — $REMAINING_AFTER remaining" \
    --body "After this claim the Telnyx pool tied to TeXML app $TELNYX_POOL_TEXML_APP_ID has only $REMAINING_AFTER unassigned DID(s) left. Buy more before the next /base-agent run." \
    >/dev/null || true
fi

# ----- Write claimed-did.json -----
OUT_PATH="$OUT_DIR/claimed-did.json"

DRY_RUN_FLAG="$DRY_RUN" \
NOW_ISO="$NOW_ISO" \
DID="$DID" \
AREA_CODE_PICKED="$PICKED_AREA" \
AREA_CODE_REQ="$AREA_CODE" \
FALLBACK_USED_FLAG="$FALLBACK_USED" \
REMAINING_AFTER_VAL="$REMAINING_AFTER" \
python3 - "$OUT_PATH" <<'PY'
import json, os, sys
out_path = sys.argv[1]
payload = {
    "did": os.environ["DID"],
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
  echo "[OK] dry-run: would claim $DID (area=$PICKED_AREA, remaining_after=$REMAINING_AFTER)"
else
  echo "[OK] picked $DID (area=$PICKED_AREA, remaining_after=$REMAINING_AFTER)"
  echo "[INFO] DID is not yet wired — run telnyx-wire-texml.sh + wire-ultravox-telephony.sh to complete the claim"
fi
echo "[INFO] wrote $OUT_PATH"
exit 0
