#!/usr/bin/env bash
# scripts/tests/test_did_race_detection.sh
#
# M23 Fix 3 (Option C) — verify telnyx-claim-did.sh's post-PATCH GET-back
# detects when a competing run wrote a different `claimed-*` tag to the
# same TeXML app. Stubs `curl` on PATH to model:
#   - list TeXML apps  → one pool-available app
#   - list phone_numbers → its bound DID
#   - PATCH tags       → 200 (we "won" the PATCH)
#   - GET app post-PATCH → returns BOTH our claimed-<slug> tag AND a
#     competing claimed-<other> tag (race lost)
#
# Expected: script exits non-zero with "Race detected".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPTS_DIR/telnyx-claim-did.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUR_SLUG="acme-co"
OTHER_SLUG="rival-co"
APP_ID="texml-app-1"
DID="+61299990001"

mkdir -p "$TMP/bin"

# Multi-call curl stub. We track call count via a counter file so we can
# return different bodies on call 1 (list apps), 2 (list phones), 3 (PATCH),
# and 4 (GET post-PATCH).
COUNTER_FILE="$TMP/curl-call-count"
echo 0 > "$COUNTER_FILE"

cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
COUNTER_FILE="$COUNTER_FILE"
APP_ID="$APP_ID"
OUR_SLUG="$OUR_SLUG"
OTHER_SLUG="$OTHER_SLUG"
DID="$DID"

# Parse args we care about (URL last positional, -o output file).
METHOD="GET"
OUT_FILE="/dev/null"
URL_TARGET=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2;;
    -o) OUT_FILE="\$2"; shift 2;;
    -w) shift 2;;
    -H) shift 2;;
    -d|--data-binary) shift 2;;
    -G) shift;;
    --data-urlencode) shift 2;;
    --ssl-no-revoke|-sS) shift;;
    *) URL_TARGET="\$1"; shift;;
  esac
done

N=\$(cat "\$COUNTER_FILE")
N=\$((N + 1))
echo "\$N" > "\$COUNTER_FILE"

case "\$N" in
  1)
    # List TeXML apps — one pool-available app.
    cat > "\$OUT_FILE" <<JSON
{"data":[{"id":"\$APP_ID","tags":["pool-available"]}]}
JSON
    printf '200'
    ;;
  2)
    # List phone_numbers — bound to our app.
    cat > "\$OUT_FILE" <<JSON
{"data":[{"phone_number":"\$DID","connection_id":"\$APP_ID"}]}
JSON
    printf '200'
    ;;
  3)
    # PATCH tags — we "won" the write.
    printf '{}' > "\$OUT_FILE"
    printf '200'
    ;;
  4)
    # GET post-PATCH — race lost: BOTH claimed-* tags present.
    cat > "\$OUT_FILE" <<JSON
{"data":{"id":"\$APP_ID","tags":["pool-available","claimed-\$OUR_SLUG","claimed-\$OTHER_SLUG"]}}
JSON
    printf '200'
    ;;
  *)
    # Any further calls (e.g. resend-alert) — return success silently.
    printf '{}' > "\$OUT_FILE"
    printf '200'
    ;;
esac
EOF
chmod +x "$TMP/bin/curl"

OUT="$TMP/out"
mkdir -p "$OUT"

PATH_BACKUP="$PATH"
export PATH="$TMP/bin:$PATH_BACKUP"
# env-check.sh sources .env from repo root — that's fine. We just need
# TELNYX_API_KEY to exist; the stub doesn't validate it.
export TELNYX_API_KEY="dummy"

set +e
OUTPUT="$(bash "$TARGET" \
  --customer-slug "$OUR_SLUG" \
  --out "$OUT" 2>&1)"
RC=$?
set -e

export PATH="$PATH_BACKUP"

if [ "$RC" -eq 0 ]; then
  echo "[FAIL] race detection: expected non-zero exit, got 0" >&2
  echo "Output: $OUTPUT" >&2
  exit 1
fi

if ! printf '%s' "$OUTPUT" | grep -q "Race detected"; then
  echo "[FAIL] race detection: 'Race detected' not in output" >&2
  echo "Output: $OUTPUT" >&2
  exit 1
fi

if ! printf '%s' "$OUTPUT" | grep -q "claimed-$OTHER_SLUG"; then
  echo "[FAIL] race detection should mention the competing tag" >&2
  echo "Output: $OUTPUT" >&2
  exit 1
fi

echo "[PASS] DID race detection halts when a competing claimed-* lands on the same app"
exit 0
