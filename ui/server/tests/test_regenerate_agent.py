"""Tests for the M13 safe-PATCH agent regenerator.

The Python helper at base-agent-setup/scripts/_ultravox_safe_patch.py does
the three Ultravox HTTP calls (GET → PATCH → GET-back) and the drift diff.
The bash orchestrator regenerate-agent.sh wraps it with Supabase lookups
(state.ultravox_agent_id, the latest system-prompt artifact) and persists
the pre-update snapshot + pushed_at timestamp.

Unit tests mock urllib.request.urlopen directly (the helper uses stdlib
urllib so the bash orchestrator can call it from a system Python without
extra deps). The integration test runs the bash orchestrator end-to-end
against live Supabase with a localhost HTTP stub server standing in for
Ultravox — we never hit the real Ultravox API in tests (it costs money +
churns a real agent).
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

import httpx
import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = REPO_ROOT / "base-agent-setup" / "scripts"
HELPER = SCRIPTS_DIR / "_ultravox_safe_patch.py"
SHELL_SCRIPT = SCRIPTS_DIR / "regenerate-agent.sh"

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")


def _resolve_bash() -> str:
    """Same logic as test_refine_flow.py — Git Bash on Windows preferred."""
    candidates = [
        os.environ.get("BASH"),
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        shutil.which("bash"),
    ]
    for c in candidates:
        if c and Path(c).exists():
            return c
    return "bash"


BASH = _resolve_bash()


def _import_helper():
    """Load the helper module by file path so tests can call run() directly."""
    cached = sys.modules.get("_ultravox_safe_patch")
    if cached is not None:
        return cached
    spec = importlib.util.spec_from_file_location("_ultravox_safe_patch", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    sys.modules["_ultravox_safe_patch"] = module
    return module


def _full_snapshot(system_prompt: str = "OLD", **overrides) -> dict:
    """A 9-field-ish Ultravox agent GET response shape, matching what
    Ultravox actually returns: top-level identity fields + nested callTemplate."""
    snap = {
        "agentId": "agent-xxxx",
        "name": "AcmePlumbing-Steve",
        "joinUrl": "https://app.ultravox.ai/join/agent-xxxx",
        "callTemplate": {
            "systemPrompt": system_prompt,
            "model": "fixie-ai/ultravox",
            "voice": {"voiceId": "voice-steve", "name": "Steve"},
            "temperature": 0.4,
            "languageHint": "en",
            "firstSpeakerSettings": {"agent": {}},
            "inactivityMessages": [{"message": "Still there?", "duration": "8s"}],
            "selectedTools": [],
        },
    }
    for k, v in overrides.items():
        if k in snap.get("callTemplate", {}):
            snap["callTemplate"][k] = v
        else:
            snap[k] = v
    return snap


# -------- Unit tests (urllib mocked) ---------------------------------------


class _FakeResp:
    """Minimal stand-in for the response object urlopen returns inside a
    `with` block — supports .status, .read(), and the context-manager API."""

    def __init__(self, status: int, body: dict | str):
        self.status = status
        if isinstance(body, str):
            self._raw = body.encode("utf-8")
        else:
            self._raw = json.dumps(body).encode("utf-8")

    def read(self) -> bytes:
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def _make_urlopen_router(
    routes: dict[str, list],
) -> tuple[callable, list[tuple[str, str, bytes | None]]]:
    """Build a urlopen replacement that pops responses off per-(method, url) lists.

    `routes` maps "<METHOD> <url>" → list of either _FakeResp instances or
    Exception instances (raised in order).

    Returns (fake_urlopen, calls) — `calls` is the recording the caller can
    assert against.
    """
    calls: list[tuple[str, str, bytes | None]] = []

    def _urlopen(req, timeout=None):  # noqa: ARG001
        method = req.get_method()
        url = req.full_url
        body = req.data
        calls.append((method, url, body))
        key = f"{method} {url}"
        queue = routes.get(key)
        if not queue:
            raise AssertionError(f"unexpected request to {key}")
        item = queue.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item

    return _urlopen, calls


def test_happy_path_patches_with_full_body_only_prompt_changed(tmp_path):
    """First GET returns 9 fields with systemPrompt=OLD; PATCH echoes back; second GET
    confirms only systemPrompt changed. Helper exits 0; PATCH body had every field."""
    helper = _import_helper()

    base = "https://ultravox.test"
    agent_id = "agent-xxxx"
    new_prompt = "NEW system prompt body."
    url = f"{base}/api/agents/{agent_id}"

    snapshot = _full_snapshot(system_prompt="OLD")
    after = _full_snapshot(system_prompt=new_prompt)

    snap_out = tmp_path / "snapshot.json"

    fake_urlopen, calls = _make_urlopen_router({
        f"GET {url}": [_FakeResp(200, snapshot), _FakeResp(200, after)],
        f"PATCH {url}": [_FakeResp(200, after)],
    })

    with patch("_ultravox_safe_patch.urllib.request.urlopen", fake_urlopen):
        rc = helper.run(
            agent_id=agent_id,
            new_prompt=new_prompt,
            pre_snapshot_out=str(snap_out),
            base=base,
            api_key="test-key",
        )

    assert rc == 0

    # Order: GET, PATCH, GET.
    methods = [m for m, _, _ in calls]
    assert methods == ["GET", "PATCH", "GET"], methods

    # PATCH body must carry every snapshot field, with only systemPrompt swapped.
    patch_call = next(c for c in calls if c[0] == "PATCH")
    assert patch_call[2] is not None
    captured_patch_body = json.loads(patch_call[2].decode("utf-8"))
    for k in ("agentId", "name", "joinUrl"):
        assert captured_patch_body[k] == snapshot[k]
    sent_ct = captured_patch_body["callTemplate"]
    snap_ct = snapshot["callTemplate"]
    assert sent_ct["systemPrompt"] == new_prompt
    for k in snap_ct:
        if k == "systemPrompt":
            continue
        assert sent_ct[k] == snap_ct[k], f"field '{k}' was not carried forward"

    # Pre-update snapshot persisted for audit/rollback.
    persisted = json.loads(snap_out.read_text(encoding="utf-8"))
    assert persisted == snapshot


@pytest.mark.parametrize(
    "field_name, before_value, after_value, expected_in_stderr",
    [
        # Voice — most visible regression (caller hears the wrong person).
        (
            "voice",
            {"voiceId": "voice-steve", "name": "Steve"},
            {"voiceId": "voice-hannah", "name": "Hannah"},
            "voice",
        ),
        # Temperature — silent quality regression. 0.4 vs 0.9 changes call feel
        # without any obvious symptom; this drift MUST be surfaced.
        ("temperature", 0.4, 0.9, "temperature"),
        # Model — capability regression. Switching mid-flight to a cheaper or
        # different family is a major incident.
        (
            "model",
            "fixie-ai/ultravox",
            "fixie-ai/ultravox-mini",
            "model",
        ),
        # firstSpeakerSettings — call-flow change. agent-first → user-first
        # silently breaks the opening greeting.
        (
            "firstSpeakerSettings",
            {"agent": {}},
            {"user": {}},
            "firstspeakersettings",
        ),
    ],
)
def test_drift_detection_named_field_changes(
    tmp_path, capsys, field_name, before_value, after_value, expected_in_stderr
):
    """Each of the four production-critical fields must trigger drift on diff:
    the helper exits 2 and the field name appears in stderr so the operator
    knows exactly what the server changed underneath the PATCH."""
    helper = _import_helper()

    base = "https://ultravox.test"
    agent_id = "agent-xxxx"
    new_prompt = "NEW prompt"
    url = f"{base}/api/agents/{agent_id}"

    snapshot = _full_snapshot(system_prompt="OLD")
    snapshot["callTemplate"][field_name] = before_value
    after = _full_snapshot(system_prompt=new_prompt)
    after["callTemplate"][field_name] = after_value

    snap_out = tmp_path / "snapshot.json"

    fake_urlopen, _ = _make_urlopen_router({
        f"GET {url}": [_FakeResp(200, snapshot), _FakeResp(200, after)],
        f"PATCH {url}": [_FakeResp(200, after)],
    })

    with patch("_ultravox_safe_patch.urllib.request.urlopen", fake_urlopen):
        rc = helper.run(
            agent_id=agent_id,
            new_prompt=new_prompt,
            pre_snapshot_out=str(snap_out),
            base=base,
            api_key="test-key",
        )

    captured = capsys.readouterr()
    assert rc == 2, captured.err
    err_lower = captured.err.lower()
    assert "drift" in err_lower
    assert expected_in_stderr in err_lower, (
        f"expected '{expected_in_stderr}' in stderr for field '{field_name}', got:\n{captured.err}"
    )


def test_drift_ignored_for_server_mutated_metadata(tmp_path, capsys):
    """updatedAt / lastActiveTime tick on every PATCH — they MUST NOT trip drift.
    Without the ignore-list the first production run halts with a benign
    'updatedAt changed' complaint; this test pins that behavior."""
    helper = _import_helper()

    base = "https://ultravox.test"
    agent_id = "agent-xxxx"
    new_prompt = "NEW prompt"
    url = f"{base}/api/agents/{agent_id}"

    snapshot = _full_snapshot(system_prompt="OLD")
    snapshot["updatedAt"] = "2026-04-27T00:00:00Z"
    snapshot["callTemplate"]["lastActiveTime"] = "2026-04-27T00:00:00Z"
    after = _full_snapshot(system_prompt=new_prompt)
    # Both timestamps tick — this is server-side bookkeeping, not real drift.
    after["updatedAt"] = "2026-04-27T00:01:33Z"
    after["callTemplate"]["lastActiveTime"] = "2026-04-27T00:01:35Z"

    snap_out = tmp_path / "snapshot.json"

    fake_urlopen, _ = _make_urlopen_router({
        f"GET {url}": [_FakeResp(200, snapshot), _FakeResp(200, after)],
        f"PATCH {url}": [_FakeResp(200, after)],
    })

    with patch("_ultravox_safe_patch.urllib.request.urlopen", fake_urlopen):
        rc = helper.run(
            agent_id=agent_id,
            new_prompt=new_prompt,
            pre_snapshot_out=str(snap_out),
            base=base,
            api_key="test-key",
        )

    captured = capsys.readouterr()
    assert rc == 0, captured.err
    assert "drift" not in captured.err.lower()


def test_initial_get_5xx_no_patch_issued(tmp_path, capsys):
    """First GET returns 500 — exit non-zero, no PATCH was issued."""
    helper = _import_helper()

    base = "https://ultravox.test"
    agent_id = "agent-xxxx"
    new_prompt = "NEW prompt"
    url = f"{base}/api/agents/{agent_id}"

    snap_out = tmp_path / "snapshot.json"

    # urlopen raises HTTPError on 5xx — model that here.
    boom = urllib.error.HTTPError(
        url, 500, "Server Error", hdrs=None, fp=io.BytesIO(b"boom")
    )
    fake_urlopen, calls = _make_urlopen_router({
        f"GET {url}": [boom],
        # If we DID try to PATCH, this fake would AssertionError when the
        # url isn't in the routes dict — so the test fails loud on regression.
    })

    with patch("_ultravox_safe_patch.urllib.request.urlopen", fake_urlopen):
        rc = helper.run(
            agent_id=agent_id,
            new_prompt=new_prompt,
            pre_snapshot_out=str(snap_out),
            base=base,
            api_key="test-key",
        )

    assert rc != 0
    # Critical: no PATCH attempted when the initial GET fails.
    methods = [m for m, _, _ in calls]
    assert "PATCH" not in methods, methods
    # And there's exactly one call total (the failed GET, no retry).
    assert len(calls) == 1

    captured = capsys.readouterr()
    err_lower = captured.err.lower()
    assert "ultravox" in err_lower
    assert ("unreachable" in err_lower or "500" in err_lower)


# Helper for the build_patch_body unit case below — covers the merge logic
# without spinning up respx.


def test_build_patch_body_preserves_every_field():
    helper = _import_helper()
    snap = _full_snapshot(system_prompt="OLD")
    body = helper.build_patch_body(snap, "NEW")
    # Top-level fields preserved.
    for k in ("agentId", "name", "joinUrl"):
        assert body[k] == snap[k]
    # callTemplate fully copied; only systemPrompt mutated.
    sent_ct = body["callTemplate"]
    snap_ct = snap["callTemplate"]
    assert sent_ct["systemPrompt"] == "NEW"
    for k in snap_ct:
        if k == "systemPrompt":
            continue
        assert sent_ct[k] == snap_ct[k], f"field '{k}' was not carried forward"


@pytest.mark.parametrize(
    "snapshot, expect_top, expect_nested",
    [
        # Both locations populated → write to both. A stale top-level shadowing
        # the new nested copy is exactly the bug this case prevents.
        (
            {"systemPrompt": "OLD", "callTemplate": {"systemPrompt": "NEST_OLD"}},
            True,
            True,
        ),
        # Only nested → only nested gets updated. Top-level is intentionally
        # NOT created (would risk shadowing on the next GET).
        ({"callTemplate": {"systemPrompt": "OLD"}}, False, True),
        # Only top-level (no callTemplate) → only top-level gets updated.
        ({"systemPrompt": "OLD"}, True, False),
        # Empty snapshot → wedge it under callTemplate so the next GET
        # surfaces the prompt where Ultravox normally returns it.
        ({}, False, True),
    ],
)
def test_build_patch_body_writes_to_every_existing_systemprompt_location(
    snapshot, expect_top, expect_nested
):
    """C2 fix: when both top-level systemPrompt AND callTemplate.systemPrompt
    exist, both must be updated. Otherwise update whichever exists; default
    to nested when neither exists."""
    helper = _import_helper()
    body = helper.build_patch_body(snapshot, "NEW")

    if expect_top:
        assert body.get("systemPrompt") == "NEW"
    else:
        assert "systemPrompt" not in body, (
            f"unexpected top-level systemPrompt in body: {body}"
        )

    if expect_nested:
        ct = body.get("callTemplate") or {}
        assert ct.get("systemPrompt") == "NEW"
    else:
        # When we only updated the top level, callTemplate (if any) must NOT
        # have systemPrompt added underneath it.
        ct = body.get("callTemplate")
        if ct is not None:
            assert "systemPrompt" not in ct


# -------- Integration test (live Supabase, mocked Ultravox) ----------------


def _skip_unless_env() -> tuple[str, str]:
    if not SUPABASE_URL or not SERVICE_KEY:
        pytest.skip("SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY unset.")
    return SUPABASE_URL, SERVICE_KEY


def _hdr(key: str) -> dict[str, str]:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
        "Content-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


@pytest.mark.integration
def test_full_flow_writes_snapshot_and_pushed_at(tmp_path):
    """Insert a customer + run with state.ultravox_agent_id, insert a system-prompt
    artifact, run regenerate-agent.sh against a respx-mocked Ultravox served by
    a local mock server, and verify the run row's state was updated correctly."""
    respx = pytest.importorskip("respx")
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"

    slug = f"regen-{uuid4().hex[:8]}"
    agent_id = "agent-test-zzzz"
    new_prompt = (
        "# System prompt v2\n"
        "You are Steve. Updated content for M13 safe-PATCH.\n"
    )

    # respx can't intercept calls from a separate bash subprocess directly —
    # mounting it via `using="httpx"` only patches the in-process httpx.
    # Workaround: spin up a tiny HTTP server (stdlib BaseHTTPServer) on a
    # localhost port and point ULTRAVOX_BASE_URL at it.
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from threading import Thread

    snapshot = _full_snapshot(system_prompt="OLD")
    after = _full_snapshot(system_prompt=new_prompt)
    captured: dict = {"patch_body": None, "calls": []}

    class _UltravoxStub(BaseHTTPRequestHandler):
        # Suppress noisy default access logs.
        def log_message(self, *a, **kw):  # noqa: D401
            return

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if not length:
                return {}
            raw = self.rfile.read(length)
            return json.loads(raw.decode("utf-8"))

        def _send(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            captured["calls"].append(("GET", self.path))
            if self.path.endswith(f"/api/agents/{agent_id}"):
                # First GET returns snapshot, second returns "after".
                gets = [c for c in captured["calls"] if c[0] == "GET"]
                payload = snapshot if len(gets) == 1 else after
                self._send(200, payload)
            else:
                self._send(404, {"error": "not found"})

        def do_PATCH(self):  # noqa: N802
            captured["calls"].append(("PATCH", self.path))
            if self.path.endswith(f"/api/agents/{agent_id}"):
                captured["patch_body"] = self._read_json()
                self._send(200, after)
            else:
                self._send(404, {"error": "not found"})

    server = HTTPServer(("127.0.0.1", 0), _UltravoxStub)
    port = server.server_port
    server_thread = Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    mock_base = f"http://127.0.0.1:{port}"

    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        cust = c.post(f"{rest}/customers", json={"slug": slug, "name": slug}).json()[0]
        run = c.post(
            f"{rest}/runs",
            json={
                "customer_id": cust["id"],
                "slug_with_ts": f"{slug}-2026-04-27T00-00-00Z",
                "started_at": datetime.now(timezone.utc).isoformat(),
                "state": {"ultravox_agent_id": agent_id},
            },
        ).json()[0]
        c.post(
            f"{rest}/artifacts",
            json={
                "run_id": run["id"],
                "artifact_name": "system-prompt",
                "content": new_prompt,
                "size_bytes": len(new_prompt.encode("utf-8")),
            },
        )
        try:
            env = os.environ.copy()
            env["USE_SUPABASE_BACKEND"] = "1"
            env["SUPABASE_OPERATOR_URL"] = base
            env["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"] = key
            env["ULTRAVOX_API_KEY"] = "test-key"
            env["ULTRAVOX_BASE_URL"] = mock_base
            result = subprocess.run(
                [BASH, str(SHELL_SCRIPT), slug],
                capture_output=True,
                text=True,
                timeout=60,
                env=env,
            )
            assert result.returncode == 0, (
                f"regenerate-agent.sh failed:\nstdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )

            # Verify the mock saw GET, PATCH, GET in that order.
            methods = [m for m, _ in captured["calls"]]
            assert methods == ["GET", "PATCH", "GET"], methods
            # The captured PATCH body must have every snapshot field, with only
            # systemPrompt swapped.
            patched = captured["patch_body"]
            assert patched is not None
            for k in ("agentId", "name", "joinUrl"):
                assert patched[k] == snapshot[k]
            sent_ct = patched["callTemplate"]
            snap_ct = snapshot["callTemplate"]
            assert sent_ct["systemPrompt"] == new_prompt
            for k in snap_ct:
                if k == "systemPrompt":
                    continue
                assert sent_ct[k] == snap_ct[k], (
                    f"field '{k}' not carried forward in PATCH body"
                )

            # Verify state was updated.
            row = c.get(
                f"{rest}/runs?id=eq.{run['id']}&select=state"
            ).json()[0]
            state = row["state"]
            assert "live_agent_pre_update" in state, list(state.keys())
            assert state["live_agent_pre_update"] == snapshot
            assert "system_prompt_pushed_at" in state
            # Sanity check the timestamp parses and is recent.
            ts = datetime.fromisoformat(state["system_prompt_pushed_at"])
            now = datetime.now(timezone.utc)
            assert (now - ts).total_seconds() < 120
        finally:
            server.shutdown()
            server.server_close()
            c.delete(f"{rest}/customers?slug=eq.{slug}")
