"""Tests for base-agent-setup/scripts/fetch_lessons.py (M11).

The helper queries operator_ui.lessons (promoted_to_prompt=false) and renders
a markdown block that gets pasted at the top of every generator prompt. It must
fail-soft: a Supabase outage or empty config must not halt /base-agent runs.

Unit tests mock the HTTP layer with respx. The integration test inserts a row
via the service role and runs the helper as a subprocess.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

import httpx
import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "base-agent-setup" / "scripts" / "fetch_lessons.py"

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")


# -------- Unit tests --------------------------------------------------------


def _import_helper():
    """Import the helper as a module so we can call its functions directly.

    The script lives outside any package, so we load it via importlib and
    cache the module in sys.modules ourselves — importlib.util.spec_from_file_location
    + exec_module does not cache automatically, so a naive call here would
    re-exec the file once per test.
    """
    cached = sys.modules.get("fetch_lessons")
    if cached is not None:
        return cached
    import importlib.util

    spec = importlib.util.spec_from_file_location("fetch_lessons", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    sys.modules["fetch_lessons"] = module
    return module


def test_render_empty_returns_empty_string():
    helper = _import_helper()
    assert helper.render_lessons([]) == ""


def test_render_two_lessons_formats_markdown_block():
    helper = _import_helper()
    lessons = [
        {
            "id": "L-001",
            "title": "Brain-doc must not invent personas.",
            "pattern": "Brain-doc fabricates caller personas.",
            "fix": "Only emit personas the meeting transcript names.",
        },
        {
            "id": "L-002",
            "title": "System prompt must quote brand phrases verbatim.",
            "pattern": "Paraphrasing customer brand voice.",
            "fix": "Always quote brand phrases word-for-word from brain-doc.",
        },
    ]
    out = helper.render_lessons(lessons)
    assert out.startswith("## Active lessons")
    assert "**L-001 — Brain-doc must not invent personas.**" in out
    assert "_Pattern:_ Brain-doc fabricates caller personas." in out
    assert "_Fix:_ Only emit personas the meeting transcript names." in out
    assert "**L-002 — System prompt must quote brand phrases verbatim.**" in out
    assert "(End of active lessons.)" in out


def test_main_empty_url_silent_exit_zero(capsys, monkeypatch):
    helper = _import_helper()
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", "")
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "")
    rc = helper.main()
    captured = capsys.readouterr()
    assert rc == 0
    assert captured.out == ""
    assert captured.err == ""


def test_main_no_lessons_prints_empty_string(monkeypatch):
    respx = pytest.importorskip("respx")
    helper = _import_helper()
    base_url = "https://example.supabase.co"
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base_url)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "fake-key")
    with respx.mock(base_url=base_url) as router:
        router.get("/rest/v1/lessons").respond(200, json=[])
        rc = helper.main()
    assert rc == 0


def test_main_two_lessons_renders_markdown(capsys, monkeypatch):
    respx = pytest.importorskip("respx")
    helper = _import_helper()
    base_url = "https://example.supabase.co"
    rows = [
        {
            "id": "L-001",
            "title": "Brain-doc must not invent personas.",
            "pattern": "Personas fabricated.",
            "fix": "Only emit personas named in the transcript.",
        },
        {
            "id": "L-002",
            "title": "Quote brand voice verbatim.",
            "pattern": "Paraphrased brand voice.",
            "fix": "Quote phrases word-for-word.",
        },
    ]
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base_url)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "fake-key")
    with respx.mock(base_url=base_url) as router:
        router.get("/rest/v1/lessons").respond(200, json=rows)
        rc = helper.main()
    captured = capsys.readouterr()
    assert rc == 0
    assert "## Active lessons" in captured.out
    assert "L-001" in captured.out
    assert "L-002" in captured.out


def test_main_500_warns_on_stderr_exits_zero(capsys, monkeypatch):
    respx = pytest.importorskip("respx")
    helper = _import_helper()
    base_url = "https://example.supabase.co"
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base_url)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "fake-key")
    with respx.mock(base_url=base_url) as router:
        router.get("/rest/v1/lessons").respond(500, text="boom")
        rc = helper.main()
    captured = capsys.readouterr()
    assert rc == 0
    assert captured.out == ""
    assert "warning" in captured.err.lower() or "fetch_lessons" in captured.err.lower()


def test_main_connect_error_retries_once_then_gives_up(capsys, monkeypatch):
    respx = pytest.importorskip("respx")
    helper = _import_helper()
    base_url = "https://example.supabase.co"
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", base_url)
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "fake-key")
    with respx.mock(base_url=base_url) as router:
        router.get("/rest/v1/lessons").mock(
            side_effect=httpx.ConnectError("boom")
        )
        rc = helper.main()
        # We expect exactly two attempts (first + one retry) before giving up.
        assert router.calls.call_count == 2
    captured = capsys.readouterr()
    assert rc == 0
    assert captured.out == ""
    # Contract: after both attempts fail, a warning trace must hit stderr so
    # the operator sees something went wrong (exit 0 alone would be silent).
    err_lower = captured.err.lower()
    assert "warning" in err_lower or "connecterror" in err_lower


# -------- Integration test --------------------------------------------------


def _skip_unless_env() -> tuple[str, str]:
    if not SUPABASE_URL or not SERVICE_ROLE_KEY:
        pytest.skip("SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY unset.")
    return SUPABASE_URL, SERVICE_ROLE_KEY


def _service_headers(key: str) -> dict[str, str]:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Profile": "operator_ui",
        "Accept-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


@pytest.mark.integration
def test_helper_subprocess_emits_inserted_lesson():
    base, key = _skip_unless_env()
    headers = _service_headers(key)
    lesson_id = f"L-test-{uuid4().hex[:8]}"
    title = f"Integration test lesson {lesson_id}"
    payload = {
        "id": lesson_id,
        "title": title,
        "pattern": "Pattern under test.",
        "fix": "Fix under test.",
        "observed_in_customer_ids": [],
        "source_feedback_ids": [],
        "promoted_to_prompt": False,
    }
    insert_url = f"{base.rstrip('/')}/rest/v1/lessons"
    with httpx.Client(timeout=15.0, headers=headers, verify=True) as c:
        ins = c.post(insert_url, json=payload)
        assert ins.status_code in (200, 201), ins.text
        try:
            env = os.environ.copy()
            env["SUPABASE_OPERATOR_URL"] = base
            env["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"] = key
            result = subprocess.run(
                [sys.executable, str(SCRIPT)],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert result.returncode == 0, result.stderr
            assert title in result.stdout, (
                f"helper stdout did not contain inserted lesson title.\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        finally:
            c.delete(f"{insert_url}?id=eq.{lesson_id}")
