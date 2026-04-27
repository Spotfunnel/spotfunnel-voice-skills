#!/usr/bin/env python3
"""Safe full-PATCH for an Ultravox agent's systemPrompt.

Invoked by regenerate-agent.sh after Supabase lookups have located the
agent_id and the new system-prompt body. This helper does the three
HTTP calls + drift verification:

  1. GET  /api/agents/{id}              — capture pre-update snapshot
  2. PATCH /api/agents/{id}             — body = snapshot ∪ {systemPrompt: NEW}
  3. GET  /api/agents/{id}              — verify; diff every non-systemPrompt field

Drift = any non-systemPrompt field that differs between the pre-update snapshot
and the post-PATCH GET. On drift, we emit the diff to stderr and exit 2 so the
operator sees exactly which field changed.

Why full-PATCH and not POST-new+DELETE-old: POST-new churns the agent_id, which
breaks Telnyx telephony_xml wiring (keyed off the agent_id). Ultravox PATCH
semantics revert any field NOT in the body to API default — so a partial PATCH
silently wipes voice/temperature/inactivity/tools. Sending the full snapshot
back with only systemPrompt changed avoids both failure modes.

CLI:
    python3 _ultravox_safe_patch.py \\
        --agent-id <id> \\
        --new-prompt-file <path> \\
        --pre-snapshot-out <path>   # writes the pre-update GET response

Stdout on success: nothing (caller reads pre-snapshot from --pre-snapshot-out).
Exit codes:
    0 — success
    1 — usage / unreachable / unexpected response
    2 — drift detected after PATCH
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# Defaultable so tests can swap in a mock base URL without rewriting the script.
DEFAULT_BASE = "https://api.ultravox.ai"
TIMEOUT_S = 30.0

# Server-side metadata fields that Ultravox mutates on every PATCH (or
# otherwise drift from API-side bookkeeping). Treating any of these as drift
# would halt the script with a benign "agent.updatedAt changed" complaint
# every single run. They get filtered out at both the top level AND inside
# nested objects (callTemplate.*) before the diff is computed.
#
# Why each:
#   updatedAt / lastUpdated / lastModified / modified / modifiedAt — generic
#       "row was touched" timestamps; almost every API stamps these on PATCH.
#   lastActiveTime / lastActivityTime — Ultravox-specific recency fields that
#       can change just from us calling GET on the agent.
_IGNORED_DRIFT_KEYS = {
    "updatedAt",
    "lastActiveTime",
    "lastModified",
    "modifiedAt",
    "lastUpdated",
    "lastActivityTime",
    "modified",
    # Ultravox auto-bumps these on every successful PATCH to systemPrompt.
    # publishedRevisionId is the new revision the API just minted; the
    # callTemplate created/updated timestamps re-stamp because Ultravox
    # treats systemPrompt swap as a callTemplate edit. None of these reflect
    # operator-meaningful drift.
    "publishedRevisionId",
    "created",
    "updated",
    "createdAt",
}


def _err(msg: str) -> None:
    print(msg, file=sys.stderr)


def _http_request(
    method: str, url: str, headers: dict[str, str], body: dict | None = None
) -> dict:
    """One urllib request returning parsed JSON. Raises RuntimeError on any
    non-2xx or transport error so the caller can convert to an exit code.

    Stdlib only — keeps the helper invocable from a bash subprocess that
    doesn't have httpx in its python3 (test integration runs the bash
    orchestrator with the system Python, not the venv's).
    """
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as e:
        snippet = e.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(
            f"Ultravox {method} {url} returned HTTP {e.code}: {snippet}"
        )
    except urllib.error.URLError as e:
        raise RuntimeError(f"Ultravox {method} {url} transport error: {e}")
    if status < 200 or status >= 300:
        snippet = raw.decode("utf-8", errors="replace")[:500]
        raise RuntimeError(
            f"Ultravox {method} {url} returned HTTP {status}: {snippet}"
        )
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError as e:
        raise RuntimeError(f"Ultravox {method} response was not JSON: {e}")


def _get_agent(base: str, agent_id: str, headers: dict[str, str]) -> dict:
    return _http_request(
        "GET", f"{base.rstrip('/')}/api/agents/{agent_id}", headers
    )


def _patch_agent(
    base: str, agent_id: str, headers: dict[str, str], body: dict
) -> dict:
    return _http_request(
        "PATCH", f"{base.rstrip('/')}/api/agents/{agent_id}", headers, body
    )


def build_patch_body(snapshot: dict, new_prompt: str) -> dict:
    """Carry every field from the snapshot forward; swap only systemPrompt.

    The snapshot is the raw GET response — we copy it, then walk to the
    systemPrompt field. Ultravox responses can surface systemPrompt at the
    top level, nested under callTemplate, or both. We update every location
    that already exists so a stale top-level copy can't shadow the new
    nested value (or vice versa). When neither exists we wedge it under
    callTemplate, since that's where Ultravox returns it on subsequent GETs.
    """
    body = json.loads(json.dumps(snapshot))  # deep copy
    ct = body.get("callTemplate")
    has_top = "systemPrompt" in body
    has_nested = isinstance(ct, dict) and "systemPrompt" in ct

    if has_top and has_nested:
        # Update both — leaving either stale risks the wrong copy winning.
        body["systemPrompt"] = new_prompt
        ct["systemPrompt"] = new_prompt
    elif has_nested:
        ct["systemPrompt"] = new_prompt
    elif has_top:
        body["systemPrompt"] = new_prompt
    else:
        # No prior systemPrompt anywhere — wedge it under callTemplate so the
        # next GET surfaces it correctly.
        body.setdefault("callTemplate", {})["systemPrompt"] = new_prompt
    return body


def diff_non_prompt_fields(before: dict, after: dict) -> list[str]:
    """Return human-readable diff lines for any non-systemPrompt drift.

    We compare the JSON-serialized form of every top-level key plus every
    key inside callTemplate, ignoring the systemPrompt key itself plus any
    server-mutated metadata fields enumerated in _IGNORED_DRIFT_KEYS (those
    fields tick on every PATCH and are not real drift).
    """
    drifts: list[str] = []

    def _norm(v: object) -> str:
        return json.dumps(v, sort_keys=True, default=str)

    # Top-level keys (excluding callTemplate, which we descend into, and
    # any expected-to-mutate metadata keys).
    keys = set(before.keys()) | set(after.keys())
    for k in sorted(keys):
        if k == "callTemplate":
            continue
        if k in _IGNORED_DRIFT_KEYS:
            continue
        b = before.get(k)
        a = after.get(k)
        if _norm(b) != _norm(a):
            drifts.append(f"  field '{k}': before={_norm(b)} after={_norm(a)}")

    # callTemplate descendants (excluding systemPrompt — that's the field
    # we deliberately mutated — and ignored metadata keys).
    bct = before.get("callTemplate") or {}
    act = after.get("callTemplate") or {}
    if isinstance(bct, dict) and isinstance(act, dict):
        keys = set(bct.keys()) | set(act.keys())
        for k in sorted(keys):
            if k == "systemPrompt":
                continue
            if k in _IGNORED_DRIFT_KEYS:
                continue
            b = bct.get(k)
            a = act.get(k)
            if _norm(b) != _norm(a):
                drifts.append(
                    f"  callTemplate.{k}: before={_norm(b)} after={_norm(a)}"
                )
    elif _norm(bct) != _norm(act):
        drifts.append(
            f"  field 'callTemplate' shape changed: "
            f"before={_norm(bct)[:200]} after={_norm(act)[:200]}"
        )

    return drifts


def run(
    agent_id: str,
    new_prompt: str,
    pre_snapshot_out: str | None,
    *,
    base: str | None = None,
    api_key: str | None = None,
) -> int:
    """Run the three-step safe-PATCH. Returns the exit code."""
    base = base or os.environ.get("ULTRAVOX_BASE_URL") or DEFAULT_BASE
    api_key = api_key or os.environ.get("ULTRAVOX_API_KEY", "")
    if not api_key:
        _err("safe-patch: ULTRAVOX_API_KEY is empty")
        return 1

    headers = {
        "X-API-Key": api_key,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    # Step 1 — GET current settings.
    try:
        snapshot = _get_agent(base, agent_id, headers)
    except RuntimeError as e:
        _err(f"safe-patch: Ultravox unreachable on initial GET — {e}")
        return 1

    # Persist the snapshot for the bash caller (used to write
    # state.live_agent_pre_update before the PATCH lands).
    if pre_snapshot_out:
        with open(pre_snapshot_out, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2)

    # Step 2 — PATCH with full body, only systemPrompt swapped.
    body = build_patch_body(snapshot, new_prompt)
    try:
        _patch_agent(base, agent_id, headers, body)
    except RuntimeError as e:
        _err(f"safe-patch: Ultravox PATCH failed — {e}")
        return 1

    # Step 3 — GET again, diff against snapshot.
    try:
        after = _get_agent(base, agent_id, headers)
    except RuntimeError as e:
        _err(f"safe-patch: Ultravox verification GET failed — {e}")
        return 1

    drifts = diff_non_prompt_fields(snapshot, after)
    if drifts:
        _err("safe-patch: drift detected after PATCH — non-systemPrompt fields changed:")
        for line in drifts:
            _err(line)
        _err(
            "safe-patch: restore by re-PATCHing the agent with the snapshot at "
            f"{pre_snapshot_out or '<no snapshot saved>'}."
        )
        return 2

    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Safe full-PATCH an Ultravox agent's systemPrompt.")
    p.add_argument("--agent-id", required=True)
    p.add_argument("--new-prompt-file", required=True)
    p.add_argument("--pre-snapshot-out", required=False, default=None)
    p.add_argument("--base-url", required=False, default=None)
    args = p.parse_args(argv)

    if not os.path.isfile(args.new_prompt_file):
        _err(f"safe-patch: --new-prompt-file not found: {args.new_prompt_file}")
        return 1
    with open(args.new_prompt_file, "r", encoding="utf-8") as f:
        new_prompt = f.read()
    if not new_prompt.strip():
        _err("safe-patch: --new-prompt-file is empty; refusing to PATCH")
        return 1

    return run(
        agent_id=args.agent_id,
        new_prompt=new_prompt,
        pre_snapshot_out=args.pre_snapshot_out,
        base=args.base_url,
    )


if __name__ == "__main__":
    raise SystemExit(main())
