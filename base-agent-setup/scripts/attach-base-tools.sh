#!/usr/bin/env bash
# scripts/attach-base-tools.sh
#
# Stage 6.5 of /base-agent. Called immediately after Stage 6 (Ultravox agent
# creation) and before Stage 7 (Telnyx DID claim). Prompts the operator for
# the customer's transfer destination + message recipient, validates the
# inputs, INSERTs operator_ui.agent_tools rows, and PATCHes the live Ultravox
# agent's selectedTools to include the two shared base tools (warmTransfer +
# takeMessage). On any failure, halts loudly — agents must never ship without
# their base tools.
#
# Usage:
#   bash scripts/attach-base-tools.sh \
#     --slug <slug> \
#     --run-id <slug_with_ts> \
#     --agent-id <ultravox_agent_id> \
#     [--transfer-phone <+61XXXXXXXXX>] \
#     [--message-email <email>]
#
# When --transfer-phone or --message-email is omitted, the script prompts
# interactively. SKILL.md typically passes them captured from operator inputs.
#
# Exit codes:
#   0  success
#   1  validation failure / missing config
#   2  Ultravox HALT (PATCH failed or drift detected)
#
# Required env (loaded via env-check.sh):
#   ULTRAVOX_API_KEY
#   ULTRAVOX_BASE_TOOL_TRANSFER_ID, ULTRAVOX_BASE_TOOL_TAKE_MESSAGE_ID
#   SUPABASE_OPERATOR_URL, SUPABASE_OPERATOR_SERVICE_ROLE_KEY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

SLUG=""
RUN_ID=""
AGENT_ID=""
TRANSFER_PHONE=""
MESSAGE_EMAIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --transfer-phone) TRANSFER_PHONE="$2"; shift 2 ;;
    --message-email) MESSAGE_EMAIL="$2"; shift 2 ;;
    *)
      echo "[err] unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

for v in SLUG RUN_ID AGENT_ID; do
  if [ -z "${!v}" ]; then
    echo "[err] --${v,,} required" >&2
    exit 1
  fi
done

# Interactive prompts when not provided. The Python orchestrator validates
# format strictly so a typo at the prompt is caught loudly.
if [ -z "$TRANSFER_PHONE" ]; then
  echo "Stage 6.5 — base tools setup"
  echo "============================"
  echo
  echo "Transfer destination: where should the agent route callers when"
  echo "they ask for a human (e.g. owner mobile, dispatch, after-hours line)?"
  echo "Format: E.164 Australian (+61 followed by 9 digits, no spaces)."
  read -r -p "  Transfer phone: " TRANSFER_PHONE
  TRANSFER_PHONE="${TRANSFER_PHONE// /}"
fi

if [ -z "$MESSAGE_EMAIL" ]; then
  echo
  echo "Message recipient: where should the agent send messages when it"
  echo "takes one on the customer's behalf (e.g. ops@business.com)."
  read -r -p "  Recipient email: " MESSAGE_EMAIL
  MESSAGE_EMAIL="${MESSAGE_EMAIL// /}"
fi

exec python3 "$SCRIPT_DIR/_attach_base_tools.py" \
  --slug "$SLUG" \
  --run-id "$RUN_ID" \
  --agent-id "$AGENT_ID" \
  --transfer-phone "$TRANSFER_PHONE" \
  --message-email "$MESSAGE_EMAIL"
