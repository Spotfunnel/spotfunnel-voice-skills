"""Integration tests for the M12 refine flow helpers.

Each test invokes one of base-agent-setup/scripts/refine-*.sh as a subprocess
and asserts the resulting Supabase state. Tests create their own customer +
run + annotation/feedback fixtures and clean up via cascade DELETE on
customers in finally blocks.

All marked integration — they hit live Supabase. Skipped when env vars
SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY are unset.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import httpx
import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = REPO_ROOT / "base-agent-setup" / "scripts"


def _resolve_bash() -> str:
    """Find a Bourne-shell that understands Windows file paths.

    On Windows, the `bash` on PATH typically resolves to WSL's bash, which
    can't see Windows-style paths the way Git Bash can. Prefer Git for Windows
    explicitly when present; otherwise fall back to whatever `bash` is.
    """
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

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")


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


def _run_script(name: str, *args: str) -> subprocess.CompletedProcess:
    """Invoke a refine helper via bash subprocess. Returns CompletedProcess.

    The shell needs SUPABASE_OPERATOR_URL + SUPABASE_OPERATOR_SERVICE_ROLE_KEY
    in env (already in os.environ when tests are run).

    On Windows / Git Bash, native Windows paths with backslashes get parsed
    as escape sequences by bash. Convert to a posix-style path so bash sees
    `/c/Users/...` and finds the script.
    """
    script = SCRIPTS_DIR / name
    return subprocess.run(
        [BASH, str(script), *args],
        capture_output=True,
        text=True,
        timeout=60,
        env=os.environ.copy(),
    )


@pytest.fixture
def fixture_run():
    """Customer + run + 3 open annotations + 1 resolved annotation.

    Yields a dict with slug, customer_id, run_id, open_ids (list[str]),
    resolved_id (str). Cleans up via cascade DELETE on customers.
    """
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    slug = f"refine-{uuid4().hex[:8]}"
    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        cust = c.post(f"{rest}/customers", json={"slug": slug, "name": slug}).json()[0]
        run = c.post(
            f"{rest}/runs",
            json={
                "customer_id": cust["id"],
                "slug_with_ts": f"{slug}-2026-01-01T00-00-00Z",
                "started_at": datetime.now(timezone.utc).isoformat(),
                "state": {},
            },
        ).json()[0]
        # Seed two artifacts so spawn-run has something to copy forward.
        c.post(
            f"{rest}/artifacts",
            json={
                "run_id": run["id"],
                "artifact_name": "brain-doc",
                "content": "# Brain doc\nDepot is in Brisbane.\n",
                "size_bytes": 36,
            },
        )
        c.post(
            f"{rest}/artifacts",
            json={
                "run_id": run["id"],
                "artifact_name": "system-prompt",
                "content": "You are Steve.\n",
                "size_bytes": 15,
            },
        )
        # Three open annotations, one already-resolved.
        open_ids = []
        for i, comment in enumerate([
            "Depot should be Melbourne not Brisbane",
            "Tone is too formal in the opener",
            "Brain-doc invents personas not in transcript",
        ]):
            r = c.post(
                f"{rest}/annotations",
                json={
                    "run_id": run["id"],
                    "artifact_name": "brain-doc",
                    "quote": f"quote-{i}",
                    "prefix": "p" * 10,
                    "suffix": "s" * 10,
                    "char_start": i * 100,
                    "char_end": i * 100 + 12,
                    "comment": comment,
                    "author_name": "test",
                },
            ).json()[0]
            open_ids.append(r["id"])
        resolved = c.post(
            f"{rest}/annotations",
            json={
                "run_id": run["id"],
                "artifact_name": "brain-doc",
                "quote": "already-resolved",
                "prefix": "p" * 10,
                "suffix": "s" * 10,
                "char_start": 999,
                "char_end": 1010,
                "comment": "this one is already done",
                "status": "resolved",
                "author_name": "test",
            },
        ).json()[0]
        try:
            yield {
                "slug": slug,
                "customer_id": cust["id"],
                "run_id": run["id"],
                "open_ids": open_ids,
                "resolved_id": resolved["id"],
            }
        finally:
            c.delete(f"{rest}/customers?slug=eq.{slug}")


# -------- 1. refine-list-annotations.sh ------------------------------------


@pytest.mark.integration
def test_list_annotations_returns_only_open_ordered(fixture_run):
    """Open annotations come out as JSONL ordered by (artifact_name, char_start).
    Resolved annotation is excluded."""
    result = _run_script("refine-list-annotations.sh", fixture_run["slug"])
    assert result.returncode == 0, result.stderr
    lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
    assert len(lines) == 3, f"expected 3 open annotations, got {len(lines)}"
    parsed = [json.loads(l) for l in lines]
    ids = [r["id"] for r in parsed]
    assert set(ids) == set(fixture_run["open_ids"])
    assert fixture_run["resolved_id"] not in ids
    starts = [r["char_start"] for r in parsed]
    assert starts == sorted(starts), "annotations not ordered by char_start"


@pytest.mark.integration
def test_list_annotations_missing_slug_halts():
    _skip_unless_env()
    result = _run_script(
        "refine-list-annotations.sh", f"no-such-customer-{uuid4().hex[:6]}"
    )
    assert result.returncode != 0
    assert "no customer" in result.stderr.lower()


# -------- 2. refine-spawn-run.sh -------------------------------------------


def _parse_spawn_stdout(stdout: str) -> tuple[str, str]:
    """refine-spawn-run.sh prints '<slug_with_ts>\\t<run_uuid>\\n'."""
    line = stdout.strip()
    parts = line.split("\t")
    assert len(parts) == 2, (
        f"refine-spawn-run.sh must print two tab-separated values, got {line!r}"
    )
    return parts[0], parts[1]


@pytest.mark.integration
def test_spawn_run_creates_new_run_with_refined_from_pointer(fixture_run):
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    result = _run_script("refine-spawn-run.sh", fixture_run["slug"])
    assert result.returncode == 0, result.stderr
    new_slug_ts, new_run_id = _parse_spawn_stdout(result.stdout)
    assert new_slug_ts.startswith(f"{fixture_run['slug']}-refine-")
    # new_run_id is the UUID PostgREST returned; sanity-check shape.
    assert re.match(r"^[0-9a-f-]{36}$", new_run_id), new_run_id
    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        rows = c.get(
            f"{rest}/runs?slug_with_ts=eq.{new_slug_ts}"
            "&select=id,refined_from_run_id,customer_id"
        ).json()
        assert len(rows) == 1
        assert rows[0]["id"] == new_run_id
        assert rows[0]["refined_from_run_id"] == fixture_run["run_id"]
        assert rows[0]["customer_id"] == fixture_run["customer_id"]


@pytest.mark.integration
def test_spawn_run_copies_artifacts_forward(fixture_run):
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    result = _run_script("refine-spawn-run.sh", fixture_run["slug"])
    assert result.returncode == 0, result.stderr
    _, new_run_id = _parse_spawn_stdout(result.stdout)
    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        old_arts = c.get(
            f"{rest}/artifacts?run_id=eq.{fixture_run['run_id']}"
            "&select=artifact_name,content"
        ).json()
        new_arts = c.get(
            f"{rest}/artifacts?run_id=eq.{new_run_id}"
            "&select=artifact_name,content"
        ).json()
        old_map = {a["artifact_name"]: a["content"] for a in old_arts}
        new_map = {a["artifact_name"]: a["content"] for a in new_arts}
        assert old_map == new_map, (
            f"artifacts not carried forward identically: "
            f"old={old_map!r} new={new_map!r}"
        )


# -------- 3. refine-resolve-annotation.sh ----------------------------------


@pytest.mark.integration
def test_resolve_annotation_flips_status_and_records_classification(fixture_run):
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    aid = fixture_run["open_ids"][0]
    # Spawn a new run to point at — refine-resolve-annotation expects a real
    # run.id for resolved_by_run_id, FK enforced.
    spawn = _run_script("refine-spawn-run.sh", fixture_run["slug"])
    assert spawn.returncode == 0, spawn.stderr
    _, new_run_id = _parse_spawn_stdout(spawn.stdout)

    result = _run_script(
        "refine-resolve-annotation.sh", aid, new_run_id, "per-run"
    )
    assert result.returncode == 0, result.stderr

    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        row = c.get(
            f"{rest}/annotations?id=eq.{aid}"
            "&select=status,resolved_by_run_id,resolved_classification"
        ).json()[0]
    assert row["status"] == "resolved"
    assert row["resolved_by_run_id"] == new_run_id
    assert row["resolved_classification"] == "per-run"


@pytest.mark.integration
@pytest.mark.parametrize("bad_class", ["garbage-class", "mixed", "Per-Run", ""])
def test_resolve_annotation_rejects_invalid_classification(fixture_run, bad_class):
    """Only 'per-run' and 'feedback' are accepted. 'mixed' was a phantom value
    in the M12 implementation — the design doc, the TS union, and the column
    never carried it. The orchestrator's mixed-branch resolves as 'feedback'."""
    aid = fixture_run["open_ids"][0]
    fake_run_id = str(uuid4())
    result = _run_script(
        "refine-resolve-annotation.sh", aid, fake_run_id, bad_class
    )
    assert result.returncode != 0
    # Empty arg trips the usage check, not the classification check.
    if bad_class:
        assert "classification" in result.stderr.lower()


# -------- 4. refine-record-feedback.sh -------------------------------------

F_ID_RE = re.compile(r"^F-\d{4}-\d{2}-\d{2}-\d{3}$")


@pytest.mark.integration
def test_record_feedback_generates_id_and_inserts_row(fixture_run):
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    aid = fixture_run["open_ids"][2]  # "Brain-doc invents personas..."
    result = _run_script("refine-record-feedback.sh", aid)
    assert result.returncode == 0, result.stderr
    fid = result.stdout.strip()
    assert F_ID_RE.match(fid), f"unexpected feedback id format: {fid!r}"
    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        row = c.get(
            f"{rest}/feedback?id=eq.{fid}"
            "&select=id,source_annotation_id,artifact_name,quote,comment,status"
        ).json()[0]
    assert row["source_annotation_id"] == aid
    assert row["artifact_name"] == "brain-doc"
    assert row["status"] == "open"


@pytest.mark.integration
def test_record_feedback_increments_within_same_day(fixture_run):
    aid_a = fixture_run["open_ids"][1]
    aid_b = fixture_run["open_ids"][2]
    a = _run_script("refine-record-feedback.sh", aid_a)
    assert a.returncode == 0, a.stderr
    b = _run_script("refine-record-feedback.sh", aid_b)
    assert b.returncode == 0, b.stderr
    fid_a = a.stdout.strip()
    fid_b = b.stdout.strip()
    # Both must match F-YYYY-MM-DD-NNN, with NNN_b > NNN_a.
    assert F_ID_RE.match(fid_a)
    assert F_ID_RE.match(fid_b)
    num_a = int(fid_a.rsplit("-", 1)[-1])
    num_b = int(fid_b.rsplit("-", 1)[-1])
    assert num_b > num_a, f"expected {fid_b} > {fid_a}"


# -------- 5. refine-cluster-feedback.sh ------------------------------------


@pytest.mark.integration
def test_cluster_feedback_groups_similar_comments(fixture_run):
    """Insert two feedback rows with the same artifact + comment-prefix and
    confirm the clusterer groups them. A third unrelated row stays unclustered."""
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    # Use refine-record-feedback for two of the open annotations to seed.
    aid_a = fixture_run["open_ids"][2]  # "Brain-doc invents personas..."
    aid_b = fixture_run["open_ids"][1]  # "Tone is too formal..."
    # Create two feedback rows with similar comment prefix via comment_override.
    a = _run_script(
        "refine-record-feedback.sh", aid_a, "Brain-doc fabricates personas"
    )
    assert a.returncode == 0, a.stderr
    b = _run_script(
        "refine-record-feedback.sh", aid_b, "Brain-doc fabricates personas"
    )
    assert b.returncode == 0, b.stderr
    # Third unrelated.
    aid_c = fixture_run["open_ids"][0]
    c_proc = _run_script(
        "refine-record-feedback.sh", aid_c, "Hours wrong on Mondays"
    )
    assert c_proc.returncode == 0, c_proc.stderr

    cluster = _run_script("refine-cluster-feedback.sh", fixture_run["slug"])
    assert cluster.returncode == 0, cluster.stderr
    lines = [l for l in cluster.stdout.strip().splitlines() if l.strip()]
    # Exactly one cluster, size 2.
    assert len(lines) == 1, f"expected 1 cluster, got {len(lines)}: {cluster.stdout}"
    parsed = json.loads(lines[0])
    assert parsed["size"] == 2
    assert set(parsed["feedback_ids"]) == {a.stdout.strip(), b.stdout.strip()}


# -------- 6. refine-elevate-cluster.sh -------------------------------------

L_ID_RE = re.compile(r"^L-\d{3}$")


@pytest.mark.integration
def test_elevate_cluster_creates_lesson_and_marks_feedback(fixture_run):
    base, key = _skip_unless_env()
    rest = f"{base.rstrip('/')}/rest/v1"
    aid_a = fixture_run["open_ids"][1]
    aid_b = fixture_run["open_ids"][2]
    a = _run_script("refine-record-feedback.sh", aid_a, "Same pattern A")
    b = _run_script("refine-record-feedback.sh", aid_b, "Same pattern A")
    assert a.returncode == 0, a.stderr
    assert b.returncode == 0, b.stderr
    fid_a = a.stdout.strip()
    fid_b = b.stdout.strip()
    csv = f"{fid_a},{fid_b}"

    elevate = _run_script(
        "refine-elevate-cluster.sh",
        csv,
        "Test lesson: pattern A",
        "Pattern A keeps recurring.",
        "Honor pattern A in all generators.",
    )
    assert elevate.returncode == 0, elevate.stderr
    lesson_id = elevate.stdout.strip()
    assert L_ID_RE.match(lesson_id), f"unexpected lesson id: {lesson_id!r}"

    try:
        with httpx.Client(timeout=15.0, headers=_hdr(SERVICE_KEY)) as c:
            lesson = c.get(
                f"{rest}/lessons?id=eq.{lesson_id}"
                "&select=id,title,pattern,fix,source_feedback_ids"
            ).json()[0]
            assert lesson["title"] == "Test lesson: pattern A"
            assert set(lesson["source_feedback_ids"]) == {fid_a, fid_b}
            fbs = c.get(
                f"{rest}/feedback?id=in.({fid_a},{fid_b})"
                "&select=id,status,elevated_to_lesson_id"
            ).json()
            assert len(fbs) == 2
            for fb in fbs:
                assert fb["status"] == "elevated"
                assert fb["elevated_to_lesson_id"] == lesson_id
    finally:
        # Lessons aren't cascade-deleted by customer FK — clean up directly.
        with httpx.Client(timeout=15.0, headers=_hdr(SERVICE_KEY)) as c:
            c.delete(f"{rest}/lessons?id=eq.{lesson_id}")
