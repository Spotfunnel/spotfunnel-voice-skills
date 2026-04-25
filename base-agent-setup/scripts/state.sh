#!/bin/bash
# scripts/state.sh
#
# Per-run state file helpers for resumability across the /base-agent flow.
# State file lives at: <repo-root>/base-agent-setup/runs/{slug}-{ISO_TS}/state.json
#
# Two ways to use:
#
#   1) Source it (preferred during a long-running invocation):
#        source scripts/state.sh
#        state_init "redgum-plumbing"
#        state_set_stage_complete 2 '{"pages": 8}'
#        next=$(state_get_next_stage)   # → 3
#
#   2) One-shot invocation (for use inside SKILL.md instructions):
#        bash scripts/state.sh state_init redgum-plumbing
#        bash scripts/state.sh state_set_stage_complete 2 '{"pages":8}'
#        bash scripts/state.sh state_get_next_stage
#
# Self-test:
#   bash scripts/state.sh --self-test
#
# Notes:
# - Uses Python3 for JSON I/O (no jq dependency — same pattern as onboard-customer).
# - Caches the active run-dir in env var STATE_RUN_DIR for subsequent calls.
# - All paths are absolute and Windows-friendly (resolved via cd && pwd).

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

# Slug-safe timestamp for directory names: 2026-04-25T13-42-07Z style (no colons).
_state_iso_slug() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ"))'
}

# state_init <slug>
# Creates runs/{slug}-{ts}/, writes initial state.json, sets STATE_RUN_DIR.
state_init() {
  local slug="$1"
  if [ -z "$slug" ]; then
    echo "state_init: slug required" >&2
    return 1
  fi
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

# Internal: locate state.json from $STATE_RUN_DIR.
_state_path() {
  if [ -z "$STATE_RUN_DIR" ]; then
    echo "STATE_RUN_DIR not set — call state_init or state_resume_from first" >&2
    return 1
  fi
  if [ ! -f "$STATE_RUN_DIR/state.json" ]; then
    echo "state.json not found at $STATE_RUN_DIR" >&2
    return 1
  fi
  echo "$STATE_RUN_DIR/state.json"
}

# state_set <key> <value>
# Sets a top-level key in state.json. Value is treated as a JSON string scalar.
state_set() {
  local key="$1"
  local value="$2"
  if [ -z "$key" ]; then
    echo "state_set: key required" >&2
    return 1
  fi
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

# state_get <key>
# Echoes the top-level key value (empty string if missing).
state_get() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "state_get: key required" >&2
    return 1
  fi
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

# state_stage_complete <stage_number> <outputs_json>
# Marks a stage done with the given outputs blob (must be valid JSON).
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

# state_get_next_stage
# Echoes the highest-numbered done stage + 1, or 1 if none.
state_get_next_stage() {
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

# state_resume_from <slug>
# Finds the most recent run-dir matching the slug, sets STATE_RUN_DIR, echoes path.
# Exits 1 if no matching dir exists.
state_resume_from() {
  local slug="$1"
  if [ -z "$slug" ]; then
    echo "state_resume_from: slug required" >&2
    return 1
  fi
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
  # Normalize the path to whatever style `cd && pwd` produces — this matches
  # state_init's output style on Windows + Git Bash (/c/... not C:/...\...).
  match="$(cd "$match" && pwd)"
  export STATE_RUN_DIR="$match"
  echo "$match"
}

# --- Self-test mode ---
_state_self_test() {
  set -e
  local tmproot
  tmproot="${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/state-self-test-$$"
  mkdir -p "$tmproot"
  # Override the runs root resolver with a tmp directory by faking SCRIPT_DIR semantics:
  # easiest path is to manually point STATE_RUN_DIR after using a local init.
  echo "[self-test] init"
  local rd
  rd="$(state_init "selftest-customer")"
  # Note: state_init's `export` happens inside the command-substitution
  # subshell, so STATE_RUN_DIR doesn't propagate back. Set it here so the
  # remaining checks can find state.json. (Real callers either source the
  # script or read STATE_RUN_DIR from the printed path the same way.)
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

  # Clean up the test run-dir we created in the real runs/ root.
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
