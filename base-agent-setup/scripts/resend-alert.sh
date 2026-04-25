#!/bin/bash
# scripts/resend-alert.sh
#
# Sends a transactional email via Resend with an in-flight 12h dedupe.
#
# Usage:
#   bash scripts/resend-alert.sh \
#     --subject "Pool low" \
#     --body "Only 2 DIDs remaining in the AU pool." \
#     --severity warn \
#     [--to ops@example.com] \
#     [--no-dedupe]
#
# Behavior:
# - Sources .env via scripts/env-check.sh (so RESEND_API_KEY, RESEND_FROM_EMAIL,
#   OPS_ALERT_EMAIL, etc., are guaranteed present).
# - Severity prefixes the subject with [info]/[warn]/[crit].
# - Uses --ssl-no-revoke (Windows + Git Bash SChannel revocation issue).
# - Dedupe cache: ${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/resend-cache.tsv
#     <subject_hash>\t<to>\t<last_sent_iso>
#   Same subject+to within 12h is skipped unless --no-dedupe is passed.
# - Body is sent as plain text AND HTML (HTML version wraps the text in <pre>).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBJECT=""
BODY=""
SEVERITY="info"
TO=""
NO_DEDUPE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --subject)    SUBJECT="$2"; shift 2 ;;
    --body)       BODY="$2"; shift 2 ;;
    --severity)   SEVERITY="$2"; shift 2 ;;
    --to)         TO="$2"; shift 2 ;;
    --no-dedupe)  NO_DEDUPE=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$SUBJECT" ] || [ -z "$BODY" ]; then
  echo "resend-alert.sh: --subject and --body are required" >&2
  exit 1
fi

case "$SEVERITY" in
  info|warn|crit) ;;
  *)
    echo "resend-alert.sh: --severity must be one of: info, warn, crit (got '$SEVERITY')" >&2
    exit 1
    ;;
esac

# Source env. env-check.sh is source-able; suppress its [OK]/[MISSING] noise unless it fails.
ENV_OUTPUT="$(set +e; source "$SCRIPT_DIR/env-check.sh" 2>&1; echo "__rc=$?")"
ENV_RC="$(echo "$ENV_OUTPUT" | tail -1 | sed 's/^__rc=//')"
if [ "$ENV_RC" != "0" ]; then
  echo "$ENV_OUTPUT" | sed '$d' >&2
  echo "resend-alert.sh: env-check failed; cannot send." >&2
  exit 1
fi
# Re-source (the subshell above didn't export into our process).
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null 2>&1
set +a

if [ -z "$TO" ]; then
  TO="$OPS_ALERT_EMAIL"
fi
if [ -z "$TO" ]; then
  echo "resend-alert.sh: no --to and OPS_ALERT_EMAIL is empty" >&2
  exit 1
fi

PREFIXED_SUBJECT="[$SEVERITY] $SUBJECT"

# --- Dedupe ---
CACHE_DIR="${TMPDIR:-$HOME/.tmp-spotfunnel-skills}"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/resend-cache.tsv"
[ -f "$CACHE_FILE" ] || : > "$CACHE_FILE"

# Hash subject (severity-prefixed) + to. Use python3 since md5sum may not be on PATH in Git Bash.
HASH="$(python3 -c "import hashlib,sys; print(hashlib.md5((sys.argv[1]+'|'+sys.argv[2]).encode()).hexdigest())" "$PREFIXED_SUBJECT" "$TO")"

if [ "$NO_DEDUPE" -eq 0 ]; then
  DEDUPE_RESULT="$(python3 - "$CACHE_FILE" "$HASH" <<'PY'
import sys, os
from datetime import datetime, timezone, timedelta

cache_path, target_hash = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc)
window = timedelta(hours=12)

last_sent_iso = None
if os.path.exists(cache_path):
    with open(cache_path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            h, _to, ts = parts[0], parts[1], parts[2]
            if h != target_hash:
                continue
            try:
                ts_dt = datetime.fromisoformat(ts)
            except ValueError:
                continue
            if now - ts_dt < window:
                last_sent_iso = ts
                break

if last_sent_iso:
    print(f"DEDUPE\t{last_sent_iso}")
else:
    print("OK")
PY
)"
  if [ "${DEDUPE_RESULT%%$'\t'*}" = "DEDUPE" ]; then
    LAST_SENT="${DEDUPE_RESULT#DEDUPE	}"
    echo "deduped (last sent $LAST_SENT)"
    exit 0
  fi
fi

# --- Build payload ---
PAYLOAD="$(python3 - "$RESEND_FROM_EMAIL" "$TO" "$PREFIXED_SUBJECT" "$BODY" <<'PY'
import json, sys, html
sender, to, subject, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
html_body = "<pre style=\"font-family:ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;\">" + html.escape(body) + "</pre>"
print(json.dumps({
    "from": sender,
    "to": [to],
    "subject": subject,
    "text": body,
    "html": html_body,
}))
PY
)"

# --- Send ---
RESP_FILE="$CACHE_DIR/resend-resp-$$.json"
HTTP_CODE="$(curl -sS --ssl-no-revoke -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "https://api.resend.com/emails" \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "202" ]; then
  echo "Resend API error (HTTP $HTTP_CODE):" >&2
  cat "$RESP_FILE" >&2
  echo >&2
  rm -f "$RESP_FILE"
  exit 1
fi
rm -f "$RESP_FILE"

# Append to dedupe cache.
NOW_ISO="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
printf "%s\t%s\t%s\n" "$HASH" "$TO" "$NOW_ISO" >> "$CACHE_FILE"

echo "sent: $SUBJECT"
exit 0
