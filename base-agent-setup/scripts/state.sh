#!/bin/bash
# scripts/state.sh
#
# Per-run state helpers for resumability across the /base-agent flow.
#
# DUAL BACKEND (Phase 4 / M8) — gated by USE_SUPABASE_BACKEND:
#
#   USE_SUPABASE_BACKEND=0 (default, unset)
#     Legacy local-file backend. State lives at:
#       <repo-root>/base-agent-setup/runs/{slug}-{ISO_TS}/state.json
#     STATE_RUN_DIR is the absolute path to that run dir.
#
#   USE_SUPABASE_BACKEND=1
#     Supabase backend. Each run is a row in operator_ui.runs keyed by
#     slug_with_ts. STATE_RUN_DIR holds the slug_with_ts (NOT a filesystem
#     path) and is the only thing the rest of the skill needs to track.
#     Requires SUPABASE_OPERATOR_URL + SUPABASE_OPERATOR_SERVICE_ROLE_KEY.
#
# Both backends expose the same six functions with the same return shapes,
# so M9 stage scripts and SKILL.md don't need to know which is active:
#
#   state_init <slug>                    -> echoes the run identifier
#   state_set <key> <value>              -> mutates current run's state
#   state_get <key>                      -> echoes value (empty if missing)
#   state_stage_complete <n> <outputs>   -> marks stage n done
#   state_get_next_stage                 -> echoes integer (1..N)
#   state_resume_from <slug>             -> echoes run id, sets STATE_RUN_DIR
#
# Two ways to use:
#
#   1) Source it (preferred during a long-running invocation):
#        source scripts/state.sh
#        state_init "redgum-plumbing"
#        state_stage_complete 2 '{"pages": 8}'
#        next=$(state_get_next_stage)   # → 3
#
#   2) One-shot invocation (for use inside SKILL.md instructions):
#        bash scripts/state.sh state_init redgum-plumbing
#        export STATE_RUN_DIR=...   # capture the printed identifier
#        bash scripts/state.sh state_set_stage_complete 2 '{"pages":8}'
#
# Self-test (legacy backend only):
#   bash scripts/state.sh --self-test
#
# Notes:
# - Uses Python3 for JSON I/O (no jq dependency).
# - Caches the active run identifier in env var STATE_RUN_DIR.
# - All paths are absolute and Windows-friendly (resolved via cd && pwd).

# --- Backend selection ---------------------------------------------------

_state_use_supabase() {
  [ "${USE_SUPABASE_BACKEND:-0}" = "1" ]
}

# Lazy-source supabase.sh — only when the flag is on, so the legacy path
# never trips on the unset SUPABASE_OPERATOR_* env vars.
_state_load_supabase() {
  if [ -z "${_STATE_SUPABASE_LOADED:-}" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck disable=SC1091
    source "$script_dir/supabase.sh"
    _STATE_SUPABASE_LOADED=1
  fi
}

# Resolve the runs/ root once. Two-levels-up from this script (scripts/state.sh)
# lands on base-agent-setup/, so runs/ is just one dir deeper.
_state_resolve_runs_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  echo "$(cd "$script_dir/.." && pwd)/runs"
}

_state_iso_now() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())'
}

# Slug-safe timestamp for run identifiers: 2026-04-25T13-42-07Z (no colons).
_state_iso_slug() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ"))'
}

# --- state_init ----------------------------------------------------------
# state_init <slug>
#   Legacy:   creates runs/{slug}-{ts}/state.json, echoes the absolute path.
#   Supabase: upserts customers row, inserts runs row with state={},
#             echoes the slug_with_ts.
# Either way: STATE_RUN_DIR is set to the echoed identifier.
state_init() {
  local slug="$1"
  if [ -z "$slug" ]; then
    echo "state_init: slug required" >&2
    return 1
  fi

  if _state_use_supabase; then
    _state_load_supabase
    local ts iso slug_with_ts customer_id body
    ts="$(_state_iso_slug)"
    iso="$(_state_iso_now)"
    slug_with_ts="${slug}-${ts}"

    # Idempotent upsert on customers (slug is unique). Use Prefer: resolution
    # so a duplicate slug doesn't 409.
    body="$(python3 -c 'import json,sys; print(json.dumps({"slug": sys.argv[1], "name": sys.argv[1]}))' "$slug")"
    curl --ssl-no-revoke -sS -X POST \
      -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
      -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
      -H "Content-Profile: $SUPABASE_OPERATOR_SCHEMA" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=representation,resolution=ignore-duplicates" \
      -d "$body" \
      "$SUPABASE_OPERATOR_URL/rest/v1/customers" \
      >/dev/null

    # Look up customer_id (works whether the insert succeeded or was ignored).
    customer_id="$(supabase_get "customers?slug=eq.${slug}&select=id" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
    if [ -z "$customer_id" ]; then
      echo "state_init: failed to resolve customer_id for slug '$slug'" >&2
      return 1
    fi

    # Insert run row with empty state jsonb.
    body="$(python3 -c '
import json, sys
print(json.dumps({
    "customer_id": sys.argv[1],
    "slug_with_ts": sys.argv[2],
    "started_at": sys.argv[3],
    "state": {},
}))
' "$customer_id" "$slug_with_ts" "$iso")"
    supabase_post "runs" "$body" >/dev/null

    export STATE_RUN_DIR="$slug_with_ts"
    echo "$slug_with_ts"
    return 0
  fi

  # --- Legacy file backend ---
  local runs_root run_dir ts iso
  runs_root="$(_state_resolve_runs_root)"
  ts="$(_state_iso_slug)"
  iso="$(_state_iso_now)"
  run_dir="$runs_root/${slug}-${ts}"
  mkdir -p "$run_dir"
  python3 - "$run_dir/state.json" "$slug" "$iso" <<'PY'
import json, sys
path, slug, started_at = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"slug": slug, "started_at": started_at, "stages": {}}, f, indent=2)
PY
  export STATE_RUN_DIR="$run_dir"
  echo "$run_dir"
}

# --- shared helpers ------------------------------------------------------

# Internal: locate state.json from $STATE_RUN_DIR (legacy only).
_state_path() {
  if [ -z "${STATE_RUN_DIR:-}" ]; then
    echo "STATE_RUN_DIR not set — call state_init or state_resume_from first" >&2
    return 1
  fi
  if [ ! -f "$STATE_RUN_DIR/state.json" ]; then
    echo "state.json not found at $STATE_RUN_DIR" >&2
    return 1
  fi
  echo "$STATE_RUN_DIR/state.json"
}

# Internal (Supabase): require STATE_RUN_DIR to be a slug_with_ts.
_state_supabase_run_id() {
  if [ -z "${STATE_RUN_DIR:-}" ]; then
    echo "STATE_RUN_DIR not set — call state_init or state_resume_from first" >&2
    return 1
  fi
  echo "$STATE_RUN_DIR"
}

# --- state_set -----------------------------------------------------------
# state_set <key> <value>
#   Legacy:   merges {key: value} into top-level state.json.
#   Supabase: merges {key: value} into operator_ui.runs.state jsonb.
# Value is treated as a string scalar. Callers wishing to store nested JSON
# should pre-serialize to a string (existing convention).
state_set() {
  local key="$1"
  local value="$2"
  if [ -z "$key" ]; then
    echo "state_set: key required" >&2
    return 1
  fi

  if _state_use_supabase; then
    _state_load_supabase
    local slug_with_ts current_state new_state body
    slug_with_ts="$(_state_supabase_run_id)" || return 1

    # Read-modify-write the jsonb. PostgREST doesn't support deep-merge in
    # PATCH on its own; one round-trip to read, one to write. State is small
    # (handful of keys) so this is fine.
    current_state="$(supabase_get "runs?slug_with_ts=eq.${slug_with_ts}&select=state" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]["state"]) if d else "{}")')"

    new_state="$(python3 -c '
import json, sys
state = json.loads(sys.argv[1])
state[sys.argv[2]] = sys.argv[3]
print(json.dumps(state))
' "$current_state" "$key" "$value")"

    body="$(python3 -c 'import json,sys; print(json.dumps({"state": json.loads(sys.argv[1])}))' "$new_state")"
    supabase_patch "runs?slug_with_ts=eq.${slug_with_ts}" "$body" >/dev/null
    return 0
  fi

  # --- Legacy ---
  local sp
  sp="$(_state_path)" || return 1
  python3 - "$sp" "$key" "$value" <<'PY'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data[key] = value
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# --- state_get -----------------------------------------------------------
# state_get <key>
#   Echoes the value (empty string if missing). Dict/list values are
#   re-serialized to JSON for the legacy backend; Supabase backend stores
#   them already as JSON in the jsonb column.
state_get() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "state_get: key required" >&2
    return 1
  fi

  if _state_use_supabase; then
    _state_load_supabase
    local slug_with_ts
    slug_with_ts="$(_state_supabase_run_id)" || return 1
    supabase_get "runs?slug_with_ts=eq.${slug_with_ts}&select=state" \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d:
    print("")
    sys.exit(0)
state = d[0]["state"] or {}
v = state.get(sys.argv[1], "")
if isinstance(v, (dict, list)):
    print(json.dumps(v))
else:
    print("" if v is None else v)
' "$key"
    return 0
  fi

  # --- Legacy ---
  local sp
  sp="$(_state_path)" || return 1
  python3 - "$sp" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
v = data.get(key, "")
if isinstance(v, (dict, list)):
    print(json.dumps(v))
else:
    print("" if v is None else v)
PY
}

# --- state_stage_complete ------------------------------------------------
# state_stage_complete <stage_number> [outputs_json]
#   Legacy:   stages.{n} = {status:"done", ts, outputs}
#   Supabase: runs.stage_complete = max(current, n). The outputs blob is
#             merged into runs.state under "stages.<n>" so stage scripts can
#             still find it. M8's primary contract is the integer column;
#             outputs are kept for parity with legacy callers.
state_stage_complete() {
  local stage="$1"
  local outputs="$2"
  if [ -z "$stage" ]; then
    echo "state_stage_complete: stage number required" >&2
    return 1
  fi
  if [ -z "$outputs" ]; then
    outputs="{}"
  fi

  if _state_use_supabase; then
    _state_load_supabase
    local slug_with_ts current iso new_state body
    slug_with_ts="$(_state_supabase_run_id)" || return 1
    iso="$(_state_iso_now)"

    # Validate outputs is JSON before writing.
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$outputs" >/dev/null 2>&1 || {
      echo "state_stage_complete: outputs must be valid JSON" >&2
      return 1
    }

    current="$(supabase_get "runs?slug_with_ts=eq.${slug_with_ts}&select=state,stage_complete" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else "null")')"
    if [ "$current" = "null" ]; then
      echo "state_stage_complete: run not found for $slug_with_ts" >&2
      return 1
    fi

    new_state="$(python3 -c '
import json, sys
row = json.loads(sys.argv[1])
stage = int(sys.argv[2])
outputs = json.loads(sys.argv[3])
ts = sys.argv[4]
state = row.get("state") or {}
stages = state.setdefault("stages", {})
stages[str(stage)] = {"status": "done", "ts": ts, "outputs": outputs}
new_stage_complete = max(int(row.get("stage_complete") or 0), stage)
print(json.dumps({"state": state, "stage_complete": new_stage_complete}))
' "$current" "$stage" "$outputs" "$iso")"

    supabase_patch "runs?slug_with_ts=eq.${slug_with_ts}" "$new_state" >/dev/null
    return 0
  fi

  # --- Legacy ---
  local sp iso
  sp="$(_state_path)" || return 1
  iso="$(_state_iso_now)"
  python3 - "$sp" "$stage" "$iso" "$outputs" <<'PY'
import json, sys
path, stage, ts, outputs_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    outputs = json.loads(outputs_raw)
except json.JSONDecodeError as e:
    print(f"state_stage_complete: outputs must be valid JSON — {e}", file=sys.stderr)
    sys.exit(1)
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
stages = data.setdefault("stages", {})
stages[str(stage)] = {"status": "done", "ts": ts, "outputs": outputs}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# Back-compat alias used in the implementation plan's verify step.
state_set_stage_complete() {
  state_stage_complete "$@"
}

# --- state_get_next_stage ------------------------------------------------
# state_get_next_stage
#   Echoes integer = highest done stage + 1, or 1 if none.
state_get_next_stage() {
  if _state_use_supabase; then
    _state_load_supabase
    local slug_with_ts
    slug_with_ts="$(_state_supabase_run_id)" || return 1
    supabase_get "runs?slug_with_ts=eq.${slug_with_ts}&select=stage_complete" \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
sc = (d[0]["stage_complete"] if d else 0) or 0
print(int(sc) + 1)
'
    return 0
  fi

  # --- Legacy ---
  local sp
  sp="$(_state_path)" || return 1
  python3 - "$sp" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
stages = data.get("stages", {})
done = []
for k, v in stages.items():
    try:
        n = int(k)
    except (TypeError, ValueError):
        continue
    if isinstance(v, dict) and v.get("status") == "done":
        done.append(n)
print((max(done) + 1) if done else 1)
PY
}

# --- state_resume_from ---------------------------------------------------
# state_resume_from <slug>
#   Legacy:   walks runs/ for the most recent {slug}-* dir, sets STATE_RUN_DIR
#             to its absolute path.
#   Supabase: queries runs ordered by started_at desc for the customer with
#             this slug, sets STATE_RUN_DIR to the latest slug_with_ts.
# Echoes the run identifier on success; returns 1 if no match.
state_resume_from() {
  local slug="$1"
  if [ -z "$slug" ]; then
    echo "state_resume_from: slug required" >&2
    return 1
  fi

  if _state_use_supabase; then
    _state_load_supabase
    local customer_id slug_with_ts
    customer_id="$(supabase_get "customers?slug=eq.${slug}&select=id" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
    if [ -z "$customer_id" ]; then
      echo "state_resume_from: no customer for slug '$slug'" >&2
      return 1
    fi
    slug_with_ts="$(supabase_get "runs?customer_id=eq.${customer_id}&order=started_at.desc&limit=1&select=slug_with_ts" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["slug_with_ts"] if d else "")')"
    if [ -z "$slug_with_ts" ]; then
      echo "state_resume_from: no runs for slug '$slug'" >&2
      return 1
    fi
    export STATE_RUN_DIR="$slug_with_ts"
    echo "$slug_with_ts"
    return 0
  fi

  # --- Legacy ---
  local runs_root
  runs_root="$(_state_resolve_runs_root)"
  if [ ! -d "$runs_root" ]; then
    echo "state_resume_from: no runs/ dir at $runs_root" >&2
    return 1
  fi
  local match
  match="$(python3 - "$runs_root" "$slug" <<'PY'
import os, sys
runs_root, slug = sys.argv[1], sys.argv[2]
prefix = f"{slug}-"
candidates = []
try:
    for name in os.listdir(runs_root):
        full = os.path.join(runs_root, name)
        if name.startswith(prefix) and os.path.isdir(full) and os.path.isfile(os.path.join(full, "state.json")):
            candidates.append((os.path.getmtime(full), full))
except FileNotFoundError:
    pass
if not candidates:
    sys.exit(2)
candidates.sort(reverse=True)
print(candidates[0][1])
PY
)"
  local rc=$?
  if [ $rc -ne 0 ] || [ -z "$match" ]; then
    echo "state_resume_from: no run-dir found for slug '$slug'" >&2
    return 1
  fi
  match="$(cd "$match" && pwd)"
  export STATE_RUN_DIR="$match"
  echo "$match"
}

# --- Self-test mode (legacy backend only) --------------------------------
_state_self_test() {
  set -e
  local tmproot
  tmproot="${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/state-self-test-$$"
  mkdir -p "$tmproot"
  echo "[self-test] init"
  local rd
  rd="$(state_init "selftest-customer")"
  # Note: state_init's `export` happens inside the command-substitution
  # subshell, so STATE_RUN_DIR doesn't propagate back. Set it here so the
  # remaining checks can find state.json.
  export STATE_RUN_DIR="$rd"
  if [ ! -f "$rd/state.json" ]; then
    echo "  [FAIL] state.json not created at $rd"; return 1
  fi
  echo "  [PASS] init created $rd"

  echo "[self-test] state_set + state_get"
  state_set "website" "https://example.com"
  local got
  got="$(state_get "website")"
  if [ "$got" = "https://example.com" ]; then
    echo "  [PASS] set/get round-trips"
  else
    echo "  [FAIL] expected 'https://example.com', got '$got'"; return 1
  fi

  echo "[self-test] missing key returns empty"
  got="$(state_get "no-such-key")"
  if [ -z "$got" ]; then
    echo "  [PASS] missing key → empty"
  else
    echo "  [FAIL] expected empty, got '$got'"; return 1
  fi

  echo "[self-test] stage completion + next-stage"
  state_stage_complete 1 '{"foo":1}'
  state_stage_complete 2 '{"scrape_size":42}'
  local nxt
  nxt="$(state_get_next_stage)"
  if [ "$nxt" = "3" ]; then
    echo "  [PASS] next stage is 3"
  else
    echo "  [FAIL] expected 3, got '$nxt'"; return 1
  fi

  echo "[self-test] resume_from finds the run"
  unset STATE_RUN_DIR
  local resumed
  resumed="$(state_resume_from "selftest-customer")"
  if [ "$resumed" = "$rd" ]; then
    echo "  [PASS] resume_from matched"
  else
    echo "  [FAIL] expected '$rd', got '$resumed'"; return 1
  fi

  echo "[self-test] resume_from for missing slug exits non-zero"
  if state_resume_from "no-such-customer-$$" >/dev/null 2>&1; then
    echo "  [FAIL] should have exited non-zero"; return 1
  else
    echo "  [PASS] missing slug → non-zero"
  fi

  rm -rf "$rd"
  rm -rf "$tmproot"
  echo "[self-test] all checks complete"
}

# Dispatch when run as `bash scripts/state.sh <fn> <args>` or --self-test.
# When sourced, $0 won't equal BASH_SOURCE so the dispatch is skipped.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    "")
      echo "Usage: bash scripts/state.sh <function> [args...]"
      echo "  state_init <slug>"
      echo "  state_set <key> <value>"
      echo "  state_get <key>"
      echo "  state_stage_complete <stage_number> <outputs_json>"
      echo "  state_get_next_stage"
      echo "  state_resume_from <slug>"
      echo "  --self-test"
      exit 1
      ;;
    --self-test)
      _state_self_test
      exit $?
      ;;
    *)
      fn="$1"
      shift
      "$fn" "$@"
      ;;
  esac
fi
