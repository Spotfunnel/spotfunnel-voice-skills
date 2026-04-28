#!/bin/bash
# scripts/cleanup-orphan-claims.sh
#
# Cleans up orphan-claimed pool DIDs from /base-agent runs that should not
# have stayed claimed. For each orphan in the hardcoded list below:
#   1. PATCH the TeXML app's voice_url back to the placeholder.
#   2. UPDATE phone_number_pool to release (assigned_user_id=NULL,
#      status='available').
#   3. (when --delete-agent is set) DELETE the Ultravox agent referenced by
#      the old voice_url. Agents don't cost standalone, so default is to
#      keep them as reference. Opt in per orphan via the AGENT_TO_DELETE
#      column in the inline data block.
#   4. (when --rm-local is set) `rm -rf` the local runs/<dir>/ directory.
#
# Does NOT touch the SpotFunnel dashboard project — use the existing
# /onboard-customer undo [slug] skill for that (cascade-deletes via
# pg_constraint dynamic FK check, captures audit trail).
#
# Default mode: --dry-run (prints planned mutations, makes no changes).
# Pass --apply to execute.
#
# Env (resolved from <repo-root>/.env directly — does not go through
# env-check.sh because that halts on the SUPABASE_URL=SUPABASE_OPERATOR_URL
# misconfig that this script needs to run alongside):
#   TELNYX_API_KEY                       required.
#   ULTRAVOX_API_KEY                     required when --delete-agent is set.
#   SUPABASE_OPERATOR_URL                 required (phone_number_pool lives in
#   SUPABASE_OPERATOR_SERVICE_ROLE_KEY    the VAM project's public schema —
#                                          same project as operator_ui).
#
# Exit codes:
#   0   all orphans cleaned up successfully (or --dry-run completed).
#   1   any mutation failed, or required env missing.

set -euo pipefail

APPLY=0
DELETE_AGENT=0
RM_LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --delete-agent) DELETE_AGENT=1; shift ;;
    --rm-local) RM_LOCAL=1; shift ;;
    --help|-h)
      cat <<'EOF'
Usage: bash scripts/cleanup-orphan-claims.sh [--dry-run|--apply]
                                              [--delete-agent] [--rm-local]

Cleans up orphan-claimed pool DIDs surfaced by the 2026-04-28 audit.
Default --dry-run prints planned mutations. --apply executes them.

--delete-agent: also DELETE the Ultravox agent referenced by each orphan's
  current voice_url (per-row opt-in via the AGENT_TO_DELETE column in the
  inline ORPHANS data block — flag controls whether opted-in rows fire).
--rm-local: also `rm -rf` each orphan's local runs/ directory (per-row
  opt-in via the LOCAL_RUN_DIR column).
EOF
      exit 0
      ;;
    *) echo "[ERR] unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve + source .env directly. Don't go through env-check.sh — that
# halts on the dual-Supabase-URL misconfig, which is precisely the state
# this cleanup script needs to run in (it cleans up DIDs claimed during
# that misconfigured period). This script doesn't touch the dashboard
# project, so the halt is over-zealous here.
ENV_PATH=""
if [ -n "${SPOTFUNNEL_SKILLS_ENV:-}" ] && [ -f "$SPOTFUNNEL_SKILLS_ENV" ]; then
  ENV_PATH="$SPOTFUNNEL_SKILLS_ENV"
elif [ -f "$REPO_ROOT/.env" ]; then
  ENV_PATH="$REPO_ROOT/.env"
fi
[ -n "$ENV_PATH" ] || { echo "[ERR] no .env found" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_PATH"
set +a

for v in TELNYX_API_KEY SUPABASE_OPERATOR_URL SUPABASE_OPERATOR_SERVICE_ROLE_KEY; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "[ERR] $v is empty" >&2; exit 1; }
done

VOICE_URL_PLACEHOLDER="https://app.ultravox.ai/api/agents/PLACEHOLDER/telephony_xml"
SUPA_REST="${SUPABASE_OPERATOR_URL%/}/rest/v1"

# Orphan claims (sourced 2026-04-28 from runs/<slug>/claimed-did.json +
# operator's per-orphan cleanup decisions).
# Format: did <TAB> texml_app_id <TAB> slug <TAB> agent_to_delete <TAB> local_run_dir <TAB> note
#   agent_to_delete = empty string if keeping; agent_id (UUID) if --delete-agent should fire.
#   local_run_dir   = empty if keeping local files; runs/<dir> path (relative to repo root) if --rm-local should fire.
#
# Teleca regen (+61291374107 / 2945699776227706652) intentionally HELD —
# slug collision with production warrants a separate cleanup pass per
# operator direction 2026-04-28.
ORPHANS="$(cat <<'EOF'
+61240727369	2945699807500437282	e2e-automateconvert-r6	2cf78135-db09-4ab8-a6e2-66f89cf2bf9a	base-agent-setup/runs/e2e-automateconvert-r6-2026-04-25T15-01-12Z-2026-04-25T15-01-12Z	2026-04-25 e2e fixture; dashboard workspace already deleted via /onboard-customer undo
EOF
)"

echo "[INFO] mode = $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)"
echo "[INFO] supabase project = $SUPABASE_OPERATOR_URL"
echo "[INFO] flags: --delete-agent=$DELETE_AGENT --rm-local=$RM_LOCAL"
echo

FAILED=0
PROCESSED=0

while IFS=$'\t' read -r DID TEXML_APP_ID SLUG AGENT_TO_DELETE LOCAL_RUN_DIR NOTE; do
  [ -z "$DID" ] && continue
  echo "── $DID (slug=$SLUG) ─────────────────────────────────────"
  echo "   note: $NOTE"
  echo "   action 1: PATCH telnyx texml_app $TEXML_APP_ID voice_url -> placeholder"
  echo "   action 2: UPDATE phone_number_pool SET assigned_user_id=NULL, status='available' WHERE did=$DID"
  if [ -n "$AGENT_TO_DELETE" ]; then
    if [ "$DELETE_AGENT" = 1 ]; then
      echo "   action 3: DELETE ultravox agent $AGENT_TO_DELETE"
    else
      echo "   action 3: (would DELETE ultravox agent $AGENT_TO_DELETE — pass --delete-agent to enable)"
    fi
  fi
  if [ -n "$LOCAL_RUN_DIR" ]; then
    if [ "$RM_LOCAL" = 1 ]; then
      echo "   action 4: rm -rf $LOCAL_RUN_DIR"
    else
      echo "   action 4: (would rm -rf $LOCAL_RUN_DIR — pass --rm-local to enable)"
    fi
  fi

  if [ "$APPLY" != 1 ]; then
    echo "   [DRY-RUN] no mutations performed"
    echo
    PROCESSED=$((PROCESSED + 1))
    continue
  fi

  # ----- Action 1: reset TeXML app voice_url -----
  PATCH_RESP="$(mktemp)"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$PATCH_RESP" -w "%{http_code}" \
    -X PATCH "https://api.telnyx.com/v2/texml_applications/$TEXML_APP_ID" \
    -H "Authorization: Bearer $TELNYX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(VOICE_URL="$VOICE_URL_PLACEHOLDER" python3 -c 'import json,os; print(json.dumps({"voice_url": os.environ["VOICE_URL"]}))')")"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "   [ERR] action 1 failed — HTTP $HTTP_CODE"
    cat "$PATCH_RESP"
    echo
    rm -f "$PATCH_RESP"
    FAILED=$((FAILED + 1))
    continue
  fi
  rm -f "$PATCH_RESP"
  echo "   [OK] action 1 complete (HTTP $HTTP_CODE)"

  # ----- Action 2: release in phone_number_pool -----
  POOL_RESP="$(mktemp)"
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$POOL_RESP" -w "%{http_code}" \
    -X PATCH "$SUPA_REST/phone_number_pool?did=eq.$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DID")" \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d '{"assigned_user_id": null, "status": "available"}')"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "   [ERR] action 2 failed — HTTP $HTTP_CODE"
    cat "$POOL_RESP"
    echo
    rm -f "$POOL_RESP"
    FAILED=$((FAILED + 1))
    continue
  fi
  # PostgREST returns 200 with body=[] when the WHERE matched 0 rows
  # (Prefer: return=representation echoes back the updated rows). Surface
  # this distinctly so a 0-row no-op doesn't masquerade as a successful
  # release. Discovered 2026-04-28 — the AutomateConvert DID had been
  # claimed via a code path that bypassed phone_number_pool, so the PATCH
  # silently matched nothing.
  POOL_ROWS="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(len(d) if isinstance(d, list) else -1)
except Exception:
    print(-1)' "$POOL_RESP")"
  rm -f "$POOL_RESP"
  if [ "$POOL_ROWS" = "0" ]; then
    echo "   [WARN] action 2 no-op — DID not in phone_number_pool (HTTP $HTTP_CODE, 0 rows updated)"
  elif [ "$POOL_ROWS" = "-1" ]; then
    echo "   [WARN] action 2 unexpected response shape (HTTP $HTTP_CODE) — assume non-fatal"
  else
    echo "   [OK] action 2 complete (HTTP $HTTP_CODE, $POOL_ROWS row(s) released)"
  fi

  # ----- Action 3 (opt-in): delete Ultravox agent -----
  if [ -n "$AGENT_TO_DELETE" ] && [ "$DELETE_AGENT" = 1 ]; then
    [ -n "${ULTRAVOX_API_KEY:-}" ] || { echo "   [ERR] ULTRAVOX_API_KEY required for --delete-agent"; FAILED=$((FAILED + 1)); continue; }
    UX_RESP="$(mktemp)"
    HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$UX_RESP" -w "%{http_code}" \
      -X DELETE "https://api.ultravox.ai/api/agents/$AGENT_TO_DELETE" \
      -H "X-API-Key: $ULTRAVOX_API_KEY")"
    if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
      echo "   [ERR] action 3 failed — HTTP $HTTP_CODE"
      cat "$UX_RESP"
      echo
      rm -f "$UX_RESP"
      FAILED=$((FAILED + 1))
      continue
    fi
    rm -f "$UX_RESP"
    echo "   [OK] action 3 complete (HTTP $HTTP_CODE)"
  fi

  # ----- Action 4 (opt-in): rm -rf local runs dir -----
  if [ -n "$LOCAL_RUN_DIR" ] && [ "$RM_LOCAL" = 1 ]; then
    FULL_PATH="$REPO_ROOT/$LOCAL_RUN_DIR"
    # Defensive: refuse to rm -rf paths that don't begin with the repo root +
    # /base-agent-setup/runs/. The whole class of "rm -rf script ate
    # something it shouldn't have" begins with a path-construction bug.
    case "$FULL_PATH" in
      "$REPO_ROOT/base-agent-setup/runs/"*)
        if [ -d "$FULL_PATH" ]; then
          rm -rf "$FULL_PATH"
          echo "   [OK] action 4 complete — removed $LOCAL_RUN_DIR"
        else
          echo "   [SKIP] action 4 — $LOCAL_RUN_DIR not present"
        fi
        ;;
      *)
        echo "   [ERR] action 4 refused — path '$FULL_PATH' is outside base-agent-setup/runs/"
        FAILED=$((FAILED + 1))
        continue
        ;;
    esac
  fi

  PROCESSED=$((PROCESSED + 1))
  echo
done <<< "$ORPHANS"

echo
echo "[INFO] summary: processed=$PROCESSED failed=$FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
