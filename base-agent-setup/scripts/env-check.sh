#!/bin/bash
# scripts/env-check.sh
#
# Resolves the spotfunnel-voice-skills .env file portably and verifies every
# required env var is non-empty. Source-able from a SKILL.md instruction or
# runnable as `bash scripts/env-check.sh` for a one-shot check.
#
# Resolution order (first hit wins):
#   1. $SPOTFUNNEL_SKILLS_ENV (explicit override)
#   2. <repo-root>/.env  (default — works from a fresh clone)
#   3. cached path at ~/.config/spotfunnel-skills/env-path
#
# Self-test:
#   bash scripts/env-check.sh --self-test
#     Runs the resolver against a temp .env containing every required var
#     plus a deliberately-missing-var check. No external API calls.

# --- Self-test mode (runs first so it doesn't trip the rest of the script) ---
if [ "$1" = "--self-test" ]; then
  set -e
  TMPROOT="${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/env-check-self-test-$$"
  mkdir -p "$TMPROOT"
  trap 'rm -rf "$TMPROOT"' EXIT

  # Build a fake .env that satisfies every required var.
  cat > "$TMPROOT/full.env" <<'EOF'
ULTRAVOX_API_KEY=stub
TELNYX_API_KEY=stub
FIRECRAWL_API_KEY=stub
SUPABASE_URL=stub
SUPABASE_SERVICE_ROLE_KEY=stub
RESEND_API_KEY=stub
RESEND_FROM_EMAIL=stub
OPS_ALERT_EMAIL=stub
REFERENCE_ULTRAVOX_AGENT_ID=stub
DASHBOARD_SERVER_URL=stub
N8N_BASE_URL=stub
N8N_API_KEY=stub
N8N_ERROR_REPORTER_WORKFLOW_ID=stub
EOF

  echo "[self-test] happy path: all vars present"
  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  if SPOTFUNNEL_SKILLS_ENV="$TMPROOT/full.env" bash "$SCRIPT_PATH" >/dev/null 2>&1; then
    echo "  [PASS] exit 0 with full env"
  else
    echo "  [FAIL] full env should have exited 0"; exit 1
  fi

  echo "[self-test] failure path: missing one var"
  cp "$TMPROOT/full.env" "$TMPROOT/missing.env"
  # Blank out ULTRAVOX_API_KEY by overwriting the line.
  sed -i.bak 's/^ULTRAVOX_API_KEY=.*/ULTRAVOX_API_KEY=/' "$TMPROOT/missing.env"
  if SPOTFUNNEL_SKILLS_ENV="$TMPROOT/missing.env" bash "$SCRIPT_PATH" >/dev/null 2>&1; then
    echo "  [FAIL] missing-var env should have exited 1"; exit 1
  else
    echo "  [PASS] exit 1 with missing var"
  fi

  echo "[self-test] failure path: no env file at all"
  if SPOTFUNNEL_SKILLS_ENV="$TMPROOT/does-not-exist.env" HOME="$TMPROOT/fake-home" bash "$SCRIPT_PATH" >/dev/null 2>&1; then
    # Note: the resolver will fall through to <repo-root>/.env if present.
    # This branch is best-effort — if a real .env exists at repo root the
    # self-test can't fully isolate. We accept either outcome here.
    echo "  [SKIP] real .env at repo root masked the no-env case"
  else
    echo "  [PASS] no env file → exit 1"
  fi

  echo "[self-test] all checks complete"
  exit 0
fi
# --- end self-test mode ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_FILE="$HOME/.config/spotfunnel-skills/env-path"

if [ -n "$SPOTFUNNEL_SKILLS_ENV" ] && [ -f "$SPOTFUNNEL_SKILLS_ENV" ]; then
  ENV_FILE="$SPOTFUNNEL_SKILLS_ENV"
elif [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [ -f "$CACHE_FILE" ] && [ -f "$(cat "$CACHE_FILE")" ]; then
  ENV_FILE="$(cat "$CACHE_FILE")"
else
  echo "No env file found. Set SPOTFUNNEL_SKILLS_ENV, or copy .env.example to <repo-root>/.env and fill in values."
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(ULTRAVOX_API_KEY TELNYX_API_KEY FIRECRAWL_API_KEY SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY RESEND_API_KEY RESEND_FROM_EMAIL OPS_ALERT_EMAIL REFERENCE_ULTRAVOX_AGENT_ID DASHBOARD_SERVER_URL N8N_BASE_URL N8N_API_KEY N8N_ERROR_REPORTER_WORKFLOW_ID)
missing=0
for v in "${required[@]}"; do
  eval "val=\$$v"
  if [ -z "$val" ]; then
    echo "[MISSING] $v"
    missing=1
  else
    echo "[OK] $v loaded"
  fi
done

if [ $missing -ne 0 ]; then
  echo "See .env.example at repo root for what each var should contain."
  return 1 2>/dev/null || exit 1
fi
