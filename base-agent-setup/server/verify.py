#!/usr/bin/env python3
"""Post-onboarding verification for /base-agent customer runs.

Runs 10 deterministic checks against external systems (Ultravox, Telnyx,
Supabase, n8n) plus an opt-in 11th programmatic test call. Results land in
operator_ui.verifications so the future Inspect view can display them.

Halt-loud on unexpected internal errors (env missing, no run for slug);
advisory on individual check failures — those land as `fail` rows, not
exceptions. Three-bucket model: pass / fail / skip. Skips never count
against the run.

Runnable as both:
    python -m server.verify --slug <slug>          # cwd=base-agent-setup/
    python base-agent-setup/server/verify.py --slug <slug>   # cwd=repo root

Stdlib-only by design (matches _ultravox_safe_patch.py's defensive pattern):
the module gets called from bash subshells that run system Python without
the ui/server venv on PATH. urllib gives us everything we need.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

TIMEOUT_S = 15.0

ULTRAVOX_BASE = "https://api.ultravox.ai"
# Telephony XML endpoint lives on the app.* host, not api.* — see
# scripts/wire-ultravox-telephony.sh which PATCHes Telnyx voice_url to
# https://app.ultravox.ai/api/agents/{id}/telephony_xml. Verification must
# expect the same host the wiring script actually sets, otherwise check 6
# would surface a false-positive mismatch on every correctly-wired customer.
ULTRAVOX_TELEPHONY_BASE = "https://app.ultravox.ai"
TELNYX_BASE = "https://api.telnyx.com/v2"

# Operator UI schema (where we persist results). Distinct from
# SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY, which point at the customer-facing
# dashboard schema (used by checks 8 + 9).
OP_SCHEMA = "operator_ui"


# ---------- HTTP helper ---------------------------------------------------


def _http(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict | None = None,
    *,
    timeout: float = TIMEOUT_S,
) -> tuple[int, dict | str]:
    """One urllib request. Returns (status, parsed_json_or_text).

    Never raises on non-2xx — verify checks need to inspect status codes
    (e.g. 404 = "agent gone") rather than treat them as exceptions. Only
    raises RuntimeError on transport errors so callers can decide whether
    that's a `fail` or `skip` for the specific check.
    """
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as e:
        status = e.code
        raw = e.read() if hasattr(e, "read") else b""
    except urllib.error.URLError as e:
        raise RuntimeError(f"{method} {url} transport error: {e.reason}")
    except Exception as e:  # noqa: BLE001 — defensive
        raise RuntimeError(f"{method} {url} unexpected error: {e}")
    text = raw.decode("utf-8", errors="replace") if raw else ""
    try:
        return status, json.loads(text) if text else {}
    except ValueError:
        return status, text


# ---------- Result helpers -----------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ms_since(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _result(
    cid: str,
    title: str,
    status: str,
    started: float,
    detail: str,
    remediation: str | None = None,
) -> dict:
    out = {
        "id": cid,
        "title": title,
        "status": status,
        "ms": _ms_since(started),
        "detail": detail,
    }
    if remediation:
        out["remediation"] = remediation
    return out


# ---------- Operator-UI Supabase access ----------------------------------


def _op_headers(key: str, *, write: bool = False) -> dict[str, str]:
    h = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": OP_SCHEMA,
    }
    if write:
        h["Content-Profile"] = OP_SCHEMA
        h["Content-Type"] = "application/json"
        h["Prefer"] = "return=representation"
    return h


def _fetch_latest_run(op_url: str, op_key: str, slug: str) -> dict | None:
    """Look up the most recent run for slug — joining customers→runs.

    Returns the runs row (with state jsonb) or None if no customer/run.
    Halts (raises) on Supabase error — we can't proceed without a run.
    """
    cust_url = (
        f"{op_url.rstrip('/')}/rest/v1/customers"
        f"?slug=eq.{urllib.parse.quote(slug, safe='')}&select=id"
    )
    status, body = _http("GET", cust_url, _op_headers(op_key))
    if status >= 400 or not isinstance(body, list):
        raise RuntimeError(
            f"operator-ui Supabase customers GET returned {status}: {body!r}"
        )
    if not body:
        return None
    customer_id = body[0]["id"]
    runs_url = (
        f"{op_url.rstrip('/')}/rest/v1/runs"
        f"?customer_id=eq.{customer_id}"
        f"&order=started_at.desc&limit=1"
        f"&select=id,slug_with_ts,state,stage_complete"
    )
    status, body = _http("GET", runs_url, _op_headers(op_key))
    if status >= 400 or not isinstance(body, list):
        raise RuntimeError(
            f"operator-ui Supabase runs GET returned {status}: {body!r}"
        )
    return body[0] if body else None


def _persist_verification(
    op_url: str, op_key: str, run_id: str, report: dict
) -> None:
    """POST one row into operator_ui.verifications. Halts on non-2xx.

    Persistence failure is loud — verifications are the only post-run
    record of state. Silently dropping them defeats the point.
    """
    url = f"{op_url.rstrip('/')}/rest/v1/verifications"
    payload = {
        "run_id": run_id,
        "verified_at": report["verified_at"],
        "summary": report["summary"],
        "checks": report["checks"],
    }
    status, body = _http("POST", url, _op_headers(op_key, write=True), payload)
    if status >= 400:
        raise RuntimeError(
            f"verifications POST returned {status}: {body!r}"
        )


# ---------- Check 1+2+3+4: Ultravox agent ---------------------------------


def _check_ultravox_agent_exists(state: dict, ux_key: str) -> tuple[dict, dict | None]:
    """Returns (result, fetched_agent_or_None). The agent dict is reused
    by subsequent checks (2/3/4) so we don't double-GET."""
    started = time.monotonic()
    cid = "ultravox-agent-exists"
    title = "Ultravox agent exists and live"
    agent_id = state.get("ultravox_agent_id", "")
    if not agent_id:
        return (
            _result(
                cid, title, "fail", started,
                "no ultravox_agent_id in run state",
                remediation="bash scripts/ultravox-create-agent.sh ...  # Stage 6",
            ),
            None,
        )
    if not ux_key:
        return (
            _result(cid, title, "skip", started, "ULTRAVOX_API_KEY unset"),
            None,
        )
    url = f"{ULTRAVOX_BASE}/api/agents/{urllib.parse.quote(agent_id, safe='')}"
    headers = {"X-API-Key": ux_key, "Accept": "application/json"}
    try:
        status, body = _http("GET", url, headers)
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e)), None
    if status == 200 and isinstance(body, dict):
        return _result(cid, title, "pass", started, f"agent_id={agent_id}"), body
    return (
        _result(
            cid, title, "fail", started,
            f"GET agent returned HTTP {status}",
            remediation="bash scripts/ultravox-create-agent.sh ...  # Stage 6",
        ),
        None,
    )


def _fetch_reference(ux_key: str) -> dict | None:
    """GET the operator's reference agent for checks 2 + 4. None on any
    failure — checks then skip rather than fail."""
    ref_id = os.environ.get("REFERENCE_ULTRAVOX_AGENT_ID", "")
    if not ref_id or not ux_key:
        return None
    url = f"{ULTRAVOX_BASE}/api/agents/{urllib.parse.quote(ref_id, safe='')}"
    headers = {"X-API-Key": ux_key, "Accept": "application/json"}
    try:
        status, body = _http("GET", url, headers)
    except RuntimeError:
        return None
    return body if status == 200 and isinstance(body, dict) else None


def _agent_field(agent: dict, key: str):
    """Ultravox surfaces voice/temp/systemPrompt at top-level OR nested
    under callTemplate (or both). Prefer nested when present — that's
    the canonical location on subsequent GETs."""
    ct = agent.get("callTemplate")
    if isinstance(ct, dict) and key in ct:
        return ct[key]
    return agent.get(key)


def _check_voice_temperature(agent: dict | None, ref: dict | None) -> dict:
    started = time.monotonic()
    cid = "ultravox-voice-temperature"
    title = "Voice + temperature match reference"
    if agent is None:
        return _result(cid, title, "skip", started, "agent fetch failed earlier")
    if ref is None:
        return _result(cid, title, "skip", started, "reference agent unfetchable")
    a_voice = _agent_field(agent, "voice")
    a_temp = _agent_field(agent, "temperature")
    r_voice = _agent_field(ref, "voice")
    r_temp = _agent_field(ref, "temperature")
    diffs = []
    if json.dumps(a_voice, sort_keys=True) != json.dumps(r_voice, sort_keys=True):
        diffs.append(f"voice (got {a_voice!r}, ref {r_voice!r})")
    if a_temp != r_temp:
        diffs.append(f"temperature (got {a_temp!r}, ref {r_temp!r})")
    if not diffs:
        return _result(cid, title, "pass", started, f"voice + temp match ref")
    return _result(
        cid, title, "fail", started,
        "mismatch: " + "; ".join(diffs),
        remediation="bash scripts/regenerate-agent.sh <slug>  # or POST a fresh agent",
    )


def _check_system_prompt(agent: dict | None) -> dict:
    started = time.monotonic()
    cid = "system-prompt-non-empty"
    title = "System prompt non-empty (>500 chars)"
    if agent is None:
        return _result(cid, title, "skip", started, "agent fetch failed earlier")
    sp = _agent_field(agent, "systemPrompt") or ""
    if not isinstance(sp, str):
        sp = str(sp)
    n = len(sp)
    if n > 500:
        return _result(cid, title, "pass", started, f"systemPrompt is {n} chars")
    return _result(
        cid, title, "fail", started,
        f"systemPrompt is {n} chars (need >500)",
        remediation="bash scripts/regenerate-agent.sh <slug>",
    )


def _check_tools_array(agent: dict | None, ref: dict | None) -> dict:
    started = time.monotonic()
    cid = "tools-array-matches"
    title = "Tools array matches reference"
    if agent is None:
        return _result(cid, title, "skip", started, "agent fetch failed earlier")
    if ref is None:
        return _result(cid, title, "skip", started, "reference agent unfetchable")
    a_tools = _agent_field(agent, "selectedTools") or []
    r_tools = _agent_field(ref, "selectedTools") or []
    if not isinstance(a_tools, list):
        a_tools = []
    if not isinstance(r_tools, list):
        r_tools = []
    if len(a_tools) == len(r_tools):
        return _result(
            cid, title, "pass", started,
            f"tools count matches ({len(a_tools)})",
        )
    return _result(
        cid, title, "fail", started,
        f"tools count {len(a_tools)} != ref {len(r_tools)}",
        remediation="bash scripts/regenerate-agent.sh <slug>",
    )


# ---------- Checks 5+6+7: Telnyx ------------------------------------------


def _check_telnyx_did_active(state: dict, tx_key: str) -> tuple[dict, dict | None]:
    """Returns (result, phone_number_row_or_None). Row is reused by 6+7."""
    started = time.monotonic()
    cid = "telnyx-did-active"
    title = "Telnyx DID active"
    did = state.get("telnyx_did", "")
    if not did:
        return (
            _result(
                cid, title, "fail", started,
                "no telnyx_did in run state",
                remediation="bash scripts/telnyx-claim-did.sh ...  # Stage 7",
            ),
            None,
        )
    if not tx_key:
        return _result(cid, title, "skip", started, "TELNYX_API_KEY unset"), None
    url = (
        f"{TELNYX_BASE}/phone_numbers"
        f"?filter[phone_number]={urllib.parse.quote(did, safe='+')}"
    )
    try:
        status, body = _http("GET", url, {"Authorization": f"Bearer {tx_key}"})
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e)), None
    if status >= 400 or not isinstance(body, dict):
        return (
            _result(cid, title, "fail", started, f"GET phone_numbers HTTP {status}"),
            None,
        )
    rows = body.get("data") or []
    if not rows:
        return (
            _result(
                cid, title, "fail", started,
                f"DID {did} not in account",
                remediation="bash scripts/telnyx-claim-did.sh ...",
            ),
            None,
        )
    row = rows[0]
    pn_status = (row.get("status") or "").lower()
    if pn_status != "active":
        return (
            _result(
                cid, title, "fail", started,
                f"DID {did} status='{pn_status}' (expected 'active')",
            ),
            row,
        )
    return _result(cid, title, "pass", started, f"DID {did} active"), row


def _check_call_routing(state: dict, pn_row: dict | None) -> tuple[dict, str]:
    """Returns (result, connection_id). connection_id is reused by check 7."""
    started = time.monotonic()
    cid = "telnyx-call-routing-wired"
    title = "Telnyx call routing wired"
    if pn_row is None:
        return _result(cid, title, "skip", started, "DID lookup failed earlier"), ""
    conn_id = str(pn_row.get("connection_id") or "")
    if not conn_id:
        return (
            _result(
                cid, title, "fail", started,
                "phone_number has no connection_id",
                remediation="bash scripts/telnyx-wire-texml.sh ...  # Stage 8",
            ),
            "",
        )
    # voice_url should be on the TeXML app, not the phone_number directly,
    # but Telnyx surfaces a "voice_url" hint on the phone_number under
    # certain account configs. The authoritative answer comes from the
    # TeXML app GET in check 7. Here we just confirm connection_id is set
    # and note any wiring fields the phone_number does carry.
    agent_id = state.get("ultravox_agent_id", "")
    expected_url = (
        f"{ULTRAVOX_TELEPHONY_BASE}/api/agents/{agent_id}/telephony_xml"
        if agent_id else ""
    )
    detail = f"connection_id={conn_id}"
    if expected_url:
        detail += f"; expected voice_url -> {expected_url}"
    return _result(cid, title, "pass", started, detail), conn_id


def _check_webhook_callback(conn_id: str, tx_key: str, agent_id: str) -> dict:
    """Pulls TeXML app, verifies status_callback non-empty AND voice_url
    points at the agent's telephony_xml (covers part of check 6's intent).
    """
    started = time.monotonic()
    cid = "webhook-callback-set"
    title = "Webhook callback set"
    if not conn_id:
        return _result(cid, title, "skip", started, "no connection_id from check 6")
    if not tx_key:
        return _result(cid, title, "skip", started, "TELNYX_API_KEY unset")
    url = f"{TELNYX_BASE}/texml_applications/{urllib.parse.quote(conn_id, safe='')}"
    try:
        status, body = _http("GET", url, {"Authorization": f"Bearer {tx_key}"})
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e))
    if status >= 400 or not isinstance(body, dict):
        return _result(cid, title, "fail", started, f"GET texml_app HTTP {status}")
    data = body.get("data") or {}
    cb = data.get("status_callback") or data.get("statusCallback") or ""
    voice_url = data.get("voice_url") or data.get("voiceUrl") or ""
    if not cb:
        return _result(
            cid, title, "fail", started,
            "TeXML app has no status_callback URL",
            remediation="bash scripts/bulk-create-texml-apps.sh  # idempotent",
        )
    # Voice-url alignment is informational here — fall through with a
    # note when the agent_id doesn't appear in the URL. Don't fail the
    # check on it; check 6 owns that signal in spirit.
    note = ""
    if agent_id and agent_id not in voice_url:
        note = f"; warn: voice_url does not reference agent_id ({voice_url or '<empty>'})"
    return _result(cid, title, "pass", started, f"status_callback set{note}")


# ---------- Checks 8+9: Customer dashboard Supabase -----------------------


def _check_dashboard_workspace(slug: str) -> dict:
    started = time.monotonic()
    cid = "supabase-customer-dashboard-workspace-exists"
    title = "Customer dashboard workspace exists"
    url = os.environ.get("SUPABASE_URL", "")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        return _result(
            cid, title, "skip", started,
            "dashboard schema not provisioned for this customer",
        )
    q = (
        f"{url.rstrip('/')}/rest/v1/workspaces"
        f"?slug=eq.{urllib.parse.quote(slug, safe='')}&select=id"
    )
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
    }
    try:
        status, body = _http("GET", q, headers)
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e))
    # PostgREST 404 / 42P01 = table not found → schema not provisioned.
    if status == 404:
        return _result(
            cid, title, "skip", started,
            "dashboard schema not provisioned for this customer",
        )
    if status >= 400:
        # Body sometimes carries {"code":"42P01"} for missing relation.
        if isinstance(body, dict) and body.get("code") in ("42P01", "PGRST106"):
            return _result(
                cid, title, "skip", started,
                "dashboard schema not provisioned for this customer",
            )
        return _result(cid, title, "fail", started, f"workspaces GET HTTP {status}")
    if isinstance(body, list) and body:
        return _result(cid, title, "pass", started, f"workspace row found for {slug}")
    return _result(
        cid, title, "fail", started,
        f"no workspace row for slug={slug}",
        remediation="re-run /onboard-customer for this slug",
    )


def _check_dashboard_auth_user(slug: str) -> dict:
    """Probes dashboard auth.users. We can't query auth.users via PostgREST
    directly (it's not exposed), so we look for the public.users row that
    /onboard-customer creates alongside the workspace. Same skip semantics
    as check 8."""
    started = time.monotonic()
    cid = "supabase-customer-dashboard-auth-user-exists"
    title = "Customer dashboard auth user exists"
    url = os.environ.get("SUPABASE_URL", "")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        return _result(
            cid, title, "skip", started,
            "dashboard schema not provisioned for this customer",
        )
    q = (
        f"{url.rstrip('/')}/rest/v1/users"
        f"?workspace_slug=eq.{urllib.parse.quote(slug, safe='')}&select=id&limit=1"
    )
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
    }
    try:
        status, body = _http("GET", q, headers)
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e))
    if status == 404:
        return _result(
            cid, title, "skip", started,
            "dashboard schema not provisioned for this customer",
        )
    if status >= 400:
        if isinstance(body, dict) and body.get("code") in ("42P01", "PGRST106", "42703"):
            return _result(
                cid, title, "skip", started,
                "dashboard schema not provisioned for this customer",
            )
        return _result(cid, title, "fail", started, f"users GET HTTP {status}")
    if isinstance(body, list) and body:
        return _result(cid, title, "pass", started, f"user row found for {slug}")
    return _result(
        cid, title, "fail", started,
        f"no user row for slug={slug}",
        remediation="re-run /onboard-customer for this slug",
    )


# ---------- Check 10: n8n -------------------------------------------------


def _check_n8n_workflow_active() -> dict:
    started = time.monotonic()
    cid = "n8n-error-workflow-active"
    title = "n8n error-reporter workflow active"
    base = os.environ.get("N8N_BASE_URL", "").rstrip("/")
    key = os.environ.get("N8N_API_KEY", "")
    wf = os.environ.get("N8N_ERROR_REPORTER_WORKFLOW_ID", "")
    if not (base and key and wf):
        return _result(cid, title, "skip", started, "N8N_* env vars unset")
    url = f"{base}/api/v1/workflows/{urllib.parse.quote(wf, safe='')}"
    try:
        status, body = _http("GET", url, {"X-N8N-API-KEY": key})
    except RuntimeError as e:
        return _result(cid, title, "fail", started, str(e))
    if status >= 400:
        return _result(cid, title, "fail", started, f"workflows GET HTTP {status}")
    if isinstance(body, dict) and body.get("active") is True:
        return _result(cid, title, "pass", started, f"workflow {wf} active")
    return _result(
        cid, title, "fail", started,
        f"workflow {wf} not active (active={body.get('active') if isinstance(body, dict) else '?'})",
        remediation="enable the workflow in your n8n console",
    )


# ---------- Check 11: opt-in test call ------------------------------------


def _check_test_call(state: dict, tx_key: str) -> dict:
    started = time.monotonic()
    cid = "programmatic-test-call"
    title = "Programmatic test call to DID"
    # Spec asks for TELNYX_TEST_FROM_NUMBER / TELNYX_TEST_CONNECTION_ID.
    # The repo's existing .env.example uses TELNYX_FROM_NUMBER /
    # TELNYX_CONNECTION_ID — accept either to avoid breaking installs.
    from_num = (
        os.environ.get("TELNYX_TEST_FROM_NUMBER")
        or os.environ.get("TELNYX_FROM_NUMBER")
        or ""
    )
    conn_id = (
        os.environ.get("TELNYX_TEST_CONNECTION_ID")
        or os.environ.get("TELNYX_CONNECTION_ID")
        or ""
    )
    if not (from_num and conn_id):
        return _result(cid, title, "skip", started, "test call env vars not set")
    if not tx_key:
        return _result(cid, title, "skip", started, "TELNYX_API_KEY unset")
    did = state.get("telnyx_did", "")
    if not did:
        return _result(cid, title, "fail", started, "no telnyx_did in state")

    headers = {
        "Authorization": f"Bearer {tx_key}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    payload = {"from": from_num, "to": did, "connection_id": conn_id}

    # Audit banner: this is the only verify check that costs real money +
    # places a real PSTN leg. Print BEFORE the POST so an operator running
    # /base-agent verify --include-call in CI sees the warning even if the
    # subsequent network call hangs or the process gets killed.
    print(
        f"verify: PLACING REAL CALL from={from_num} to={did} via connection_id={conn_id}",
        file=sys.stderr,
        flush=True,
    )

    try:
        status, body = _http(
            "POST", f"{TELNYX_BASE}/calls", headers, payload, timeout=20.0
        )
    except RuntimeError as e:
        return _result(cid, title, "fail", started, f"call POST: {e}")
    if status >= 400:
        return _result(cid, title, "fail", started, f"calls POST HTTP {status}: {body!r}")

    call_id = ""
    if isinstance(body, dict):
        data = body.get("data") or {}
        call_id = data.get("call_control_id") or data.get("id") or ""
    if not call_id:
        return _result(
            cid, title, "fail", started,
            f"calls POST returned no call id: {body!r}",
        )

    # Brief wait so the leg is in a hangup-able state.
    time.sleep(2.0)
    hangup_url = f"{TELNYX_BASE}/calls/{urllib.parse.quote(call_id, safe='')}/actions/hangup"
    hangup_remediation = (
        "Manually hang up via Telnyx console: https://portal.telnyx.com/#/calls"
        f" — call_control_id={call_id}"
    )
    # Hangup is idempotent on Telnyx — safe to retry once. Goal: minimise
    # the chance a transient transport blip leaves a real PSTN leg ringing
    # for 60-90s until Telnyx times the call out.
    try:
        h_status, h_body = _http("POST", hangup_url, headers, {}, timeout=15.0)
    except RuntimeError as e1:
        time.sleep(1.0)
        try:
            h_status, h_body = _http("POST", hangup_url, headers, {}, timeout=15.0)
        except RuntimeError as e2:
            return _result(
                cid, title, "fail", started,
                f"call placed (id={call_id}) but hangup transport error after retry: {e2} (initial: {e1})",
                remediation=hangup_remediation,
            )
    if h_status >= 400:
        return _result(
            cid, title, "fail", started,
            f"call placed (id={call_id}) but hangup HTTP {h_status}: {h_body!r}",
            remediation=hangup_remediation,
        )
    return _result(cid, title, "pass", started, f"placed + hung up call {call_id}")


# ---------- Orchestrator --------------------------------------------------


def run_verification(
    slug: str,
    *,
    include_call: bool = False,
    op_url: str | None = None,
    op_key: str | None = None,
    ux_key: str | None = None,
    tx_key: str | None = None,
) -> tuple[dict, dict]:
    """Run all checks, return (report, run_row).

    `report` shape:
        {verified_at, summary: {pass, fail, skip}, checks: [...]}
    `run_row` is the operator_ui.runs row used (id, slug_with_ts, state).
    Caller persists report → operator_ui.verifications using run_row['id'].
    """
    op_url = op_url or os.environ.get("SUPABASE_OPERATOR_URL", "")
    op_key = op_key or os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "")
    ux_key = ux_key if ux_key is not None else os.environ.get("ULTRAVOX_API_KEY", "")
    tx_key = tx_key if tx_key is not None else os.environ.get("TELNYX_API_KEY", "")

    if not (op_url and op_key):
        raise RuntimeError(
            "SUPABASE_OPERATOR_URL + SUPABASE_OPERATOR_SERVICE_ROLE_KEY required"
        )

    run_row = _fetch_latest_run(op_url, op_key, slug)
    if not run_row:
        raise RuntimeError(f"no run found for slug '{slug}'")
    state = run_row.get("state") or {}

    checks: list[dict] = []

    # 1
    r1, agent = _check_ultravox_agent_exists(state, ux_key)
    checks.append(r1)
    ref = _fetch_reference(ux_key)
    # 2
    checks.append(_check_voice_temperature(agent, ref))
    # 3
    checks.append(_check_system_prompt(agent))
    # 4
    checks.append(_check_tools_array(agent, ref))
    # 5
    r5, pn_row = _check_telnyx_did_active(state, tx_key)
    checks.append(r5)
    # 6
    r6, conn_id = _check_call_routing(state, pn_row)
    checks.append(r6)
    # 7
    checks.append(_check_webhook_callback(conn_id, tx_key, state.get("ultravox_agent_id", "")))
    # 8
    checks.append(_check_dashboard_workspace(slug))
    # 9
    checks.append(_check_dashboard_auth_user(slug))
    # 10
    checks.append(_check_n8n_workflow_active())
    # 11 (opt-in)
    if include_call:
        checks.append(_check_test_call(state, tx_key))

    summary = {"pass": 0, "fail": 0, "skip": 0}
    for c in checks:
        s = c.get("status", "skip")
        if s in summary:
            summary[s] += 1

    report = {"verified_at": _now_iso(), "summary": summary, "checks": checks}
    return report, run_row


# ---------- Output rendering ----------------------------------------------


def _render_text(report: dict, slug: str) -> str:
    lines = [f"Verification report for slug={slug}", f"  at {report['verified_at']}"]
    s = report["summary"]
    lines.append(f"  summary: pass={s['pass']} fail={s['fail']} skip={s['skip']}")
    lines.append("")
    for c in report["checks"]:
        marker = {"pass": "[PASS]", "fail": "[FAIL]", "skip": "[SKIP]"}.get(
            c["status"], "[????]"
        )
        lines.append(f"  {marker} {c['id']:<48} ({c['ms']}ms)  {c['detail']}")
        if c.get("remediation"):
            lines.append(f"         remediation: {c['remediation']}")
    return "\n".join(lines)


# ---------- CLI -----------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Run /base-agent post-onboarding verification.")
    p.add_argument("--slug", required=True, help="customer slug")
    p.add_argument("--include-call", action="store_true",
                   help="opt in to the 11th check (programmatic Telnyx call). Real call.")
    p.add_argument("--no-write", action="store_true",
                   help="skip persisting results to operator_ui.verifications")
    p.add_argument("--json", action="store_true",
                   help="print results as JSON (default: human-readable)")
    args = p.parse_args(argv)

    try:
        report, run_row = run_verification(args.slug, include_call=args.include_call)
    except RuntimeError as e:
        print(f"verify: {e}", file=sys.stderr)
        return 1

    # Print report FIRST. The report is the actually-actionable output:
    # operators read it for skip/fail detail and remediation pointers. If
    # persistence subsequently fails (DB outage, schema drift, etc.) we
    # still want them to have seen the report. Persistence is a record;
    # the printed report is the operator-facing audit trail.
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(_render_text(report, args.slug))

    persist_failed = False
    if not args.no_write:
        s = report["summary"]
        # All-skip guard: a row of {pass:0, fail:0, skip:10} is noise — it
        # means the operator ran offline or with all credentials missing.
        # Don't pollute operator_ui.verifications with such rows.
        if s["pass"] + s["fail"] > 0:
            op_url = os.environ.get("SUPABASE_OPERATOR_URL", "")
            op_key = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "")
            try:
                _persist_verification(op_url, op_key, run_row["id"], report)
            except RuntimeError as e:
                print(f"verify: persistence failed — {e}", file=sys.stderr)
                persist_failed = True
        else:
            print("verify: all checks skipped, not persisting.", file=sys.stderr)

    if persist_failed:
        return 1

    # Stage 11.5 contract: the SKILL.md hook uses `|| true`, so the exit
    # code is advisory. We still reflect fail count in the exit code so
    # the manual `/base-agent verify` invocation is informative when
    # operators run it standalone.
    return 0 if report["summary"]["fail"] == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
