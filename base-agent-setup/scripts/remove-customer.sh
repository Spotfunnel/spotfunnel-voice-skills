#!/usr/bin/env bash
# scripts/remove-customer.sh
#
# Wrapper for /base-agent remove [slug]. Resolves env, then dispatches to
# the Python orchestrator at scripts/_remove_customer.py which does the
# actual multi-system teardown (Supabase operator_ui + dashboard, Telnyx,
# Ultravox, local filesystem).
#
# Usage:
#   bash scripts/remove-customer.sh <slug> [--dry-run] [--yes]
#
# Required env (loaded via env-check.sh):
#   SUPABASE_OPERATOR_URL, SUPABASE_OPERATOR_SERVICE_ROLE_KEY
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (dashboard schema)
#   TELNYX_API_KEY
#   ULTRAVOX_API_KEY
#
# Exit codes:
#   0  success (zero residue verified)
#   1  user aborted, validation failure, or residue after teardown
#   2  HALT: Telnyx or Ultravox failure during teardown — re-run after fix

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: bash scripts/remove-customer.sh <slug> [--dry-run] [--yes]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

exec python3 "$SCRIPT_DIR/_remove_customer.py" "$@"
