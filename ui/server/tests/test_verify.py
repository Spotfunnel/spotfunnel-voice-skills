"""Tests for the M15-M17 verify module.

The module at base-agent-setup/server/verify.py runs 10 deterministic checks
plus an opt-in 11th programmatic test call. Unit tests mock urllib at the
HTTP layer (the module is stdlib-only by design — see _ultravox_safe_patch.py
for the pattern). Persistence is exercised via a live-Supabase fixture
under @pytest.mark.integration.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from unittest.mock import patch
from uuid import uuid4

import httpx
import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE = REPO_ROOT / "base-agent-setup" / "server" / "verify.py"

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")


def _import_module():
    """Load verify.py by file path. Cached so multiple tests share state.

    Imported as `verify_under_test` to avoid clashing with any other
    'verify' module on sys.modules in this venv.
    """
    cached = sys.modules.get("verify_under_test")
    if cached is not None:
        return cached
    spec = importlib.util.spec_from_file_location("verify_under_test", MODULE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    sys.modules["verify_under_test"] = module
    return module


# ---------- urllib router (same pattern as test_regenerate_agent.py) -----


class _FakeResp:
    def __init__(self, status: int, body):
        self.status = status
        if isinstance(body, str):
            self._raw = body.encode("utf-8")
        elif isinstance(body, (bytes, bytearray)):
            self._raw = bytes(body)
        else:
            self._raw = json.dumps(body).encode("utf-8")

    def read(self) -> bytes:
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class _FakeHTTPError(urllib.error.HTTPError):
    """An HTTPError instance pre-built with a body. urlopen raises this for
    non-2xx; the verify module catches and inspects the .code + .read()."""

    def __init__(self, url: str, code: int, body):
        if isinstance(body, (dict, list)):
            raw = json.dumps(body).encode("utf-8")
        else:
            raw = (body or "").encode("utf-8") if isinstance(body, str) else b""
        super().__init__(url, code, "test-error", {}, None)
        self._body = raw

    def read(self) -> bytes:
        return self._body


def _router(routes: dict[str, list]) -> tuple[Callable, list]:
    """Pop responses off per-(method, url-prefix) lists. URLs match by prefix
    so query strings (filter[phone_number]=...) don't break the lookup."""
    calls: list[tuple[str, str, bytes | None]] = []

    def _urlopen(req, timeout=None):  # noqa: ARG001
        method = req.get_method()
        url = req.full_url
        body = req.data
        calls.append((method, url, body))
        # Find the longest prefix match — so a more specific URL wins over
        # a base host.
        candidates = [
            k for k in routes
            if k.startswith(method + " ") and url.startswith(k.split(" ", 1)[1])
        ]
        if not candidates:
            raise AssertionError(f"unexpected request to {method} {url}")
        key = max(candidates, key=lambda k: len(k.split(" ", 1)[1]))
        queue = routes[key]
        if not queue:
            raise AssertionError(f"queue empty for {key}")
        item = queue.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item

    return _urlopen, calls


# ---------- Fixture builders ---------------------------------------------


SLUG = "verify-fixture"
RUN_ID = "run-uuid-1"
AGENT_ID = "agent-xxxx"
DID = "+61299990000"
CONN_ID = "telnyx-app-1"


def _state(**overrides) -> dict:
    s = {"ultravox_agent_id": AGENT_ID, "telnyx_did": DID}
    s.update(overrides)
    return s


def _agent(system_prompt_chars: int = 1000, voice="Steve", temp=0.4, tools=None):
    if tools is None:
        tools = [{"name": "x"}, {"name": "y"}]
    return {
        "agentId": AGENT_ID,
        "callTemplate": {
            "systemPrompt": "x" * system_prompt_chars,
            "voice": {"voiceId": "v-1", "name": voice},
            "temperature": temp,
            "selectedTools": tools,
        },
    }


def _ref_agent(voice="Steve", temp=0.4, tools=None):
    return _agent(system_prompt_chars=2000, voice=voice, temp=temp, tools=tools)


def _phone_number_row(status="active", connection_id=CONN_ID, did=DID) -> dict:
    return {
        "data": [
            {
                "id": "pn-1",
                "phone_number": did,
                "status": status,
                "connection_id": connection_id,
            }
        ]
    }


def _texml_app(status_callback="https://hook.example.com/call-ended", voice_url=None) -> dict:
    if voice_url is None:
        voice_url = f"https://app.ultravox.ai/api/agents/{AGENT_ID}/telephony_xml"
    return {
        "data": {
            "id": CONN_ID,
            "status_callback": status_callback,
            "voice_url": voice_url,
        }
    }


def _all_routes_happy(extra: dict | None = None, *, artifact_chars: int = 1000) -> dict:
    """Default route map for happy-path tests. Specific tests override
    individual entries.

    M23: check 3 (system-prompt-matches-artifact) requires the live agent's
    systemPrompt and the operator_ui.artifacts content to be byte-equal.
    The fixture builds both from `_agent(system_prompt_chars=N)` and a
    matching artifact row of length N. Specific tests override the artifact
    row's content to test mismatch.
    """
    OP = "https://op.test"
    DASH = "https://dash.test"
    N8N = "https://n8n.test"
    artifact_content = "x" * artifact_chars
    routes: dict[str, list] = {
        # Operator UI Supabase: customer + run lookups
        f"GET {OP}/rest/v1/customers": [_FakeResp(200, [{"id": "cust-1"}])],
        f"GET {OP}/rest/v1/runs": [_FakeResp(200, [{
            "id": RUN_ID,
            "slug_with_ts": f"{SLUG}-2026-01-01T00-00-00Z",
            "state": _state(),
            "stage_complete": 11,
        }])],
        # M23 Fix 6: system-prompt artifact lookup (operator_ui.artifacts).
        # Default returns the same content the live agent fixture has.
        f"GET {OP}/rest/v1/artifacts": [_FakeResp(200, [{"content": artifact_content}])],
        # Persistence
        f"POST {OP}/rest/v1/verifications": [_FakeResp(201, [{"id": "v-1"}])],
        # Ultravox: agent + reference
        f"GET https://api.ultravox.ai/api/agents/{AGENT_ID}": [_FakeResp(200, _agent(system_prompt_chars=artifact_chars))],
        "GET https://api.ultravox.ai/api/agents/ref-agent": [_FakeResp(200, _ref_agent())],
        # Telnyx phone number + texml app
        "GET https://api.telnyx.com/v2/phone_numbers": [_FakeResp(200, _phone_number_row())],
        f"GET https://api.telnyx.com/v2/texml_applications/{CONN_ID}": [_FakeResp(200, _texml_app())],
        # Customer dashboard Supabase: workspace + user
        f"GET {DASH}/rest/v1/workspaces": [_FakeResp(200, [{"id": "ws-1"}])],
        f"GET {DASH}/rest/v1/users": [_FakeResp(200, [{"id": "u-1"}])],
        # n8n
        f"GET {N8N}/api/v1/workflows/wf-1": [_FakeResp(200, {"active": True})],
    }
    if extra:
        routes.update(extra)
    return routes


def _happy_env(monkeypatch):
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", "https://op.test")
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "op-key")
    monkeypatch.setenv("ULTRAVOX_API_KEY", "ux-key")
    monkeypatch.setenv("TELNYX_API_KEY", "tx-key")
    monkeypatch.setenv("REFERENCE_ULTRAVOX_AGENT_ID", "ref-agent")
    monkeypatch.setenv("SUPABASE_URL", "https://dash.test")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "dash-key")
    monkeypatch.setenv("N8N_BASE_URL", "https://n8n.test")
    monkeypatch.setenv("N8N_API_KEY", "n8n-key")
    monkeypatch.setenv("N8N_ERROR_REPORTER_WORKFLOW_ID", "wf-1")
    # Ensure test-call vars are absent unless a test sets them.
    for v in ("TELNYX_TEST_FROM_NUMBER", "TELNYX_TEST_CONNECTION_ID",
              "TELNYX_FROM_NUMBER", "TELNYX_CONNECTION_ID"):
        monkeypatch.delenv(v, raising=False)


# ---------- Unit tests ----------------------------------------------------


def test_happy_path_all_ten_pass(monkeypatch):
    _happy_env(monkeypatch)
    mod = _import_module()
    fake, _calls = _router(_all_routes_happy())
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, run_row = mod.run_verification(SLUG)
    assert report["summary"] == {"pass": 10, "fail": 0, "skip": 0}, report["checks"]
    assert run_row["id"] == RUN_ID
    ids = [c["id"] for c in report["checks"]]
    assert ids == [
        "ultravox-agent-exists",
        "ultravox-voice-temperature",
        "system-prompt-matches-artifact",
        "tools-array-matches",
        "telnyx-did-active",
        "telnyx-call-routing-wired",
        "webhook-callback-set",
        "supabase-customer-dashboard-workspace-exists",
        "supabase-customer-dashboard-auth-user-exists",
        "n8n-error-workflow-active",
    ]
    for c in report["checks"]:
        assert c["status"] == "pass", c
        assert "ms" in c and isinstance(c["ms"], int)


def test_ultravox_404_fails_check_one_and_skips_dependents(monkeypatch):
    """Documents the cascade choice: when the agent GET 404s, checks 2-4
    'skip' (we can't compare voice/temp/prompt/tools without an agent).
    Check 1 itself is 'fail' with remediation."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes[f"GET https://api.ultravox.ai/api/agents/{AGENT_ID}"] = [
        _FakeHTTPError(f"https://api.ultravox.ai/api/agents/{AGENT_ID}", 404, {"error": "not found"})
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["ultravox-agent-exists"]["status"] == "fail"
    assert "404" in by_id["ultravox-agent-exists"]["detail"]
    assert "ultravox-create-agent.sh" in by_id["ultravox-agent-exists"]["remediation"]
    for cid in ("ultravox-voice-temperature", "system-prompt-matches-artifact", "tools-array-matches"):
        assert by_id[cid]["status"] == "skip", by_id[cid]


def test_telnyx_404_fails_check_5_and_skips_dependents(monkeypatch):
    """Documents the cascade choice: when phone_numbers GET 404s, check 5
    is 'fail' and checks 6 (call routing) + 7 (webhook callback) 'skip' —
    we can't inspect routing or callbacks without a phone_number row.
    Mirrors test_ultravox_404_fails_check_one_and_skips_dependents for the
    Telnyx side of the chain (I4 cascade)."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://api.telnyx.com/v2/phone_numbers"] = [
        _FakeHTTPError("https://api.telnyx.com/v2/phone_numbers", 404, {"errors": [{"title": "not found"}]})
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["telnyx-did-active"]["status"] == "fail"
    assert "404" in by_id["telnyx-did-active"]["detail"]
    assert by_id["telnyx-call-routing-wired"]["status"] == "skip"
    assert "lookup failed" in by_id["telnyx-call-routing-wired"]["detail"]
    assert by_id["webhook-callback-set"]["status"] == "skip"
    assert "no connection_id" in by_id["webhook-callback-set"]["detail"]


def test_reference_agent_404_skips_checks_2_and_4(monkeypatch):
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://api.ultravox.ai/api/agents/ref-agent"] = [
        _FakeHTTPError("https://api.ultravox.ai/api/agents/ref-agent", 404, {})
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["ultravox-voice-temperature"]["status"] == "skip"
    assert by_id["tools-array-matches"]["status"] == "skip"
    # Check 3 still passes — system prompt depends on the customer agent
    # plus the operator_ui artifact (both fetched fine in this test).
    assert by_id["system-prompt-matches-artifact"]["status"] == "pass"


def test_dashboard_table_404_skips_checks_8_and_9(monkeypatch):
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://dash.test/rest/v1/workspaces"] = [
        _FakeHTTPError("https://dash.test/rest/v1/workspaces", 404, {"code": "42P01"})
    ]
    routes["GET https://dash.test/rest/v1/users"] = [
        _FakeHTTPError("https://dash.test/rest/v1/users", 404, {"code": "42P01"})
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["supabase-customer-dashboard-workspace-exists"]["status"] == "skip"
    assert by_id["supabase-customer-dashboard-auth-user-exists"]["status"] == "skip"
    assert "not provisioned" in by_id["supabase-customer-dashboard-workspace-exists"]["detail"]


def test_n8n_workflow_inactive_fails_check_10(monkeypatch):
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://n8n.test/api/v1/workflows/wf-1"] = [
        _FakeResp(200, {"active": False})
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["n8n-error-workflow-active"]["status"] == "fail"
    assert "not active" in by_id["n8n-error-workflow-active"]["detail"]


def test_include_call_passes_when_env_set(monkeypatch):
    _happy_env(monkeypatch)
    monkeypatch.setenv("TELNYX_TEST_FROM_NUMBER", "+61288887777")
    monkeypatch.setenv("TELNYX_TEST_CONNECTION_ID", "test-conn-out")
    mod = _import_module()
    # Speed: stub time.sleep so the 2-second wait doesn't slow the test.
    monkeypatch.setattr(mod.time, "sleep", lambda _s: None)
    routes = _all_routes_happy({
        "POST https://api.telnyx.com/v2/calls": [
            _FakeResp(200, {"data": {"call_control_id": "call-abc-123"}})
        ],
        "POST https://api.telnyx.com/v2/calls/call-abc-123/actions/hangup": [
            _FakeResp(200, {"data": {"result": "ok"}})
        ],
    })
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG, include_call=True)
    assert len(report["checks"]) == 11
    last = report["checks"][-1]
    assert last["id"] == "programmatic-test-call"
    assert last["status"] == "pass"
    assert "call-abc-123" in last["detail"]


def test_include_call_skips_without_env(monkeypatch):
    _happy_env(monkeypatch)
    # Test-call env vars deliberately absent (cleared in _happy_env).
    mod = _import_module()
    fake, _calls = _router(_all_routes_happy())
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG, include_call=True)
    assert len(report["checks"]) == 11
    last = report["checks"][-1]
    assert last["id"] == "programmatic-test-call"
    assert last["status"] == "skip"
    assert "test call env vars not set" in last["detail"]


def test_telnyx_did_inactive_fails(monkeypatch):
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://api.telnyx.com/v2/phone_numbers"] = [
        _FakeResp(200, _phone_number_row(status="suspended"))
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["telnyx-did-active"]["status"] == "fail"
    assert "suspended" in by_id["telnyx-did-active"]["detail"]


def test_system_prompt_artifact_too_short_fails(monkeypatch):
    """M23 Fix 6: artifact length floor preserved as a sanity check.
    A < 500 char artifact (probably empty generation) should fail even
    if the live agent matches it byte-for-byte."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    # Both sides set to the same 42 chars — the byte-equal would pass, but
    # the length floor catches the suspiciously-short artifact case.
    short = "x" * 42
    routes["GET https://op.test/rest/v1/artifacts"] = [
        _FakeResp(200, [{"content": short}])
    ]
    routes[f"GET https://api.ultravox.ai/api/agents/{AGENT_ID}"] = [
        _FakeResp(200, _agent(system_prompt_chars=42))
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["system-prompt-matches-artifact"]["status"] == "fail"
    assert "suspiciously short" in by_id["system-prompt-matches-artifact"]["detail"]


def test_system_prompt_content_mismatch_fails(monkeypatch):
    """M23 Fix 6: live agent has the prompt content, but the latest artifact
    in operator_ui.artifacts differs from it (e.g. operator regenerated the
    artifact but forgot to push to live Ultravox via regenerate-agent.sh)."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    # Live agent has 1000 'x's; artifact has 1000 'y's. Same length, content
    # differs everywhere — diff summary should report mismatched_chars==1000.
    routes["GET https://op.test/rest/v1/artifacts"] = [
        _FakeResp(200, [{"content": "y" * 1000}])
    ]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    chk = by_id["system-prompt-matches-artifact"]
    assert chk["status"] == "fail"
    assert "differs from latest artifact" in chk["detail"]
    assert "regenerate-agent.sh" in chk["remediation"]


def test_system_prompt_no_artifact_skips(monkeypatch):
    """M23 Fix 6: skip when the operator_ui.artifacts row is absent
    (legacy run that pre-dates artifact mirroring)."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://op.test/rest/v1/artifacts"] = [_FakeResp(200, [])]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        report, _ = mod.run_verification(SLUG)
    by_id = {c["id"]: c for c in report["checks"]}
    assert by_id["system-prompt-matches-artifact"]["status"] == "skip"


def test_no_run_for_slug_raises(monkeypatch):
    """Halt-loud: missing run is an internal error, not a check failure."""
    _happy_env(monkeypatch)
    mod = _import_module()
    routes = _all_routes_happy()
    routes["GET https://op.test/rest/v1/customers"] = [_FakeResp(200, [])]
    fake, _calls = _router(routes)
    with patch("verify_under_test.urllib.request.urlopen", fake):
        with pytest.raises(RuntimeError, match="no run found"):
            mod.run_verification("does-not-exist")


# ---------- CLI smoke -----------------------------------------------------


def _resolve_python() -> str:
    """Use the same interpreter the test is running under."""
    return sys.executable


def test_cli_smoke_no_write_json(monkeypatch, tmp_path):
    """Invoke verify.py as a subprocess with --no-write --json. We stub
    urlopen by writing a tiny shim module on PYTHONPATH that intercepts
    requests via http.server is overkill — instead we run the module
    directly and use a small wrapper script that monkeypatches urlopen
    before importing verify."""
    # Build a wrapper that loads the verify module with patched urlopen.
    wrapper = tmp_path / "wrapper.py"
    routes_payload = {
        "customers": [{"id": "cust-1"}],
        "runs": [{"id": RUN_ID, "slug_with_ts": f"{SLUG}-x", "state": _state(), "stage_complete": 11}],
        # M23 Fix 6: artifact must match the live agent's systemPrompt for
        # check 3 (system-prompt-matches-artifact) to pass.
        "artifacts": [{"content": "x" * 1000}],
        "agent": _agent(),
        "ref": _ref_agent(),
        "phone_numbers": _phone_number_row(),
        "texml": _texml_app(),
        "workspaces": [{"id": "ws-1"}],
        "users": [{"id": "u-1"}],
        "n8n": {"active": True},
    }
    wrapper.write_text(
        "import json, sys, importlib.util, urllib.request\n"
        # Embed routes as a JSON string + parse at runtime — Python's bool
        # literals (True/False/None) don't match JSON's true/false/null
        # when dumped raw into source.
        f"ROUTES = json.loads({json.dumps(json.dumps(routes_payload))})\n"
        "AGENT_ID = " + json.dumps(AGENT_ID) + "\n"
        "CONN_ID = " + json.dumps(CONN_ID) + "\n"
        "class _R:\n"
        "    def __init__(self, status, body):\n"
        "        self.status = status\n"
        "        self._raw = json.dumps(body).encode('utf-8')\n"
        "    def read(self): return self._raw\n"
        "    def __enter__(self): return self\n"
        "    def __exit__(self, *_): return False\n"
        "def _fake(req, timeout=None):\n"
        "    url = req.full_url\n"
        "    if '/customers' in url: return _R(200, ROUTES['customers'])\n"
        "    if '/runs' in url: return _R(200, ROUTES['runs'])\n"
        "    if '/artifacts' in url: return _R(200, ROUTES['artifacts'])\n"
        "    if 'agents/' + AGENT_ID in url: return _R(200, ROUTES['agent'])\n"
        "    if 'agents/ref-agent' in url: return _R(200, ROUTES['ref'])\n"
        "    if 'phone_numbers' in url: return _R(200, ROUTES['phone_numbers'])\n"
        "    if 'texml_applications/' + CONN_ID in url: return _R(200, ROUTES['texml'])\n"
        "    if '/workspaces' in url: return _R(200, ROUTES['workspaces'])\n"
        "    if '/users' in url: return _R(200, ROUTES['users'])\n"
        "    if '/workflows/' in url: return _R(200, ROUTES['n8n'])\n"
        "    raise AssertionError('unexpected url ' + url)\n"
        "urllib.request.urlopen = _fake\n"
        f"spec = importlib.util.spec_from_file_location('verify_under_test', {json.dumps(str(MODULE))})\n"
        "module = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(module)\n"
        "module.urllib.request.urlopen = _fake\n"
        "sys.exit(module.main(sys.argv[1:]))\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env.update({
        "SUPABASE_OPERATOR_URL": "https://op.test",
        "SUPABASE_OPERATOR_SERVICE_ROLE_KEY": "op-key",
        "ULTRAVOX_API_KEY": "ux-key",
        "TELNYX_API_KEY": "tx-key",
        "REFERENCE_ULTRAVOX_AGENT_ID": "ref-agent",
        "SUPABASE_URL": "https://dash.test",
        "SUPABASE_SERVICE_ROLE_KEY": "dash-key",
        "N8N_BASE_URL": "https://n8n.test",
        "N8N_API_KEY": "n8n-key",
        "N8N_ERROR_REPORTER_WORKFLOW_ID": "wf-1",
        # Strip any inherited test-call envs.
        "TELNYX_TEST_FROM_NUMBER": "",
        "TELNYX_TEST_CONNECTION_ID": "",
        "TELNYX_FROM_NUMBER": "",
        "TELNYX_CONNECTION_ID": "",
    })
    proc = subprocess.run(
        [_resolve_python(), str(wrapper), "--slug", SLUG, "--no-write", "--json"],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
    payload = json.loads(proc.stdout)
    assert payload["summary"]["pass"] == 10
    assert payload["summary"]["fail"] == 0


# ---------- Live Supabase persistence test (integration) ------------------


def _live_skip() -> tuple[str, str]:
    if not (SUPABASE_URL and SERVICE_KEY):
        pytest.skip("SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY unset.")
    return SUPABASE_URL, SERVICE_KEY


def _hdr(key: str, write: bool = False) -> dict[str, str]:
    h = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
    }
    if write:
        h["Content-Profile"] = "operator_ui"
        h["Content-Type"] = "application/json"
        h["Prefer"] = "return=representation"
    return h


@pytest.fixture
def live_run():
    base, svc = _live_skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    slug = f"verify-persist-{uuid4().hex[:8]}"
    with httpx.Client(timeout=15.0, headers=_hdr(svc, write=True)) as c:
        cust = c.post(f"{rest}/customers", json={"slug": slug, "name": slug}).json()[0]
        run = c.post(
            f"{rest}/runs",
            json={
                "customer_id": cust["id"],
                "slug_with_ts": f"{slug}-2026-01-01T00-00-00Z",
                "started_at": datetime.now(timezone.utc).isoformat(),
                "state": {
                    "ultravox_agent_id": "agent-x",
                    "telnyx_did": "+61299990000",
                },
                "stage_complete": 11,
            },
        ).json()[0]
        try:
            yield {"slug": slug, "customer_id": cust["id"], "run_id": run["id"]}
        finally:
            # Cascade deletes annotations + verifications + artifacts via FK.
            c.delete(f"{rest}/customers?slug=eq.{slug}")


@pytest.mark.integration
def test_persistence_round_trip(live_run, monkeypatch):
    """Without --no-write, the report should land in operator_ui.verifications
    keyed by run_id, and the row should round-trip exactly."""
    base, svc = _live_skip()
    mod = _import_module()
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", svc)

    report = {
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "summary": {"pass": 7, "fail": 1, "skip": 2},
        "checks": [
            {"id": "fake-check", "title": "Fake", "status": "pass", "ms": 12, "detail": "ok"},
        ],
    }
    mod._persist_verification(base, svc, live_run["run_id"], report)

    # Round-trip via httpx (avoid mixing the verify module's urllib path).
    rest = f"{base.rstrip('/')}/rest/v1"
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
        rows = c.get(
            f"{rest}/verifications",
            params={"run_id": f"eq.{live_run['run_id']}", "select": "*"},
        ).json()
    assert len(rows) == 1, rows
    row = rows[0]
    assert row["summary"] == report["summary"]
    assert row["checks"] == report["checks"]


@pytest.mark.integration
def test_no_write_skips_persistence(live_run, monkeypatch):
    """With --no-write, the verifications table should remain empty for
    this run_id even after run_verification completes."""
    base, svc = _live_skip()
    mod = _import_module()
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", svc)
    monkeypatch.setenv("ULTRAVOX_API_KEY", "")
    monkeypatch.setenv("TELNYX_API_KEY", "")
    monkeypatch.setenv("REFERENCE_ULTRAVOX_AGENT_ID", "")
    # Mock urlopen so external HTTP calls return predictable skip/fail
    # without hitting real services.
    fake, _calls = _router({
        f"GET {base.rstrip('/')}/rest/v1/customers": [_FakeResp(200, [{"id": live_run["customer_id"]}])],
        f"GET {base.rstrip('/')}/rest/v1/runs": [_FakeResp(200, [{
            "id": live_run["run_id"],
            "slug_with_ts": f"{live_run['slug']}-x",
            "state": {"ultravox_agent_id": "agent-x", "telnyx_did": "+61299990000"},
            "stage_complete": 11,
        }])],
        # M23 Fix 6: empty artifacts → check 3 skips cleanly (no row to compare).
        f"GET {base.rstrip('/')}/rest/v1/artifacts": [_FakeResp(200, [])],
    })
    # Other URLs (Ultravox, Telnyx, n8n, dashboard) — return URLError so
    # checks 1, 5 fail and the rest skip cleanly.
    def _wrapped(req, timeout=None):
        url = req.full_url
        if url.startswith(base):
            return fake(req, timeout=timeout)
        raise urllib.error.URLError("no network in test")
    rest = f"{base.rstrip('/')}/rest/v1"
    # Ensure no leftover rows.
    with httpx.Client(timeout=15.0, headers=_hdr(svc, write=True)) as c:
        c.delete(f"{rest}/verifications?run_id=eq.{live_run['run_id']}")
    with patch("verify_under_test.urllib.request.urlopen", _wrapped):
        report, _row = mod.run_verification(live_run["slug"])
    # Don't call _persist_verification — that's what --no-write means.
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
        rows = c.get(
            f"{rest}/verifications",
            params={"run_id": f"eq.{live_run['run_id']}", "select": "id"},
        ).json()
    assert rows == [], rows
    # Sanity: the report still has all 10 checks.
    assert len(report["checks"]) == 10
