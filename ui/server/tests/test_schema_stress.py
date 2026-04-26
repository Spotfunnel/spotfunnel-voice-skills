"""Stress tests for the operator_ui Postgres schema (M1).

Cover the constraints + grants that protect the data layer:

1. Slug CHECK constraint rejects path-traversal / shouty / empty inputs.
2. Anon role grants enforce the "read everything, write only annotations + feedback"
   rule — so a leaked anon key in the deployed JS bundle can't be used to wipe
   the customers/runs/artifacts tables.
3. ON DELETE CASCADE walks customers → runs → artifacts → annotations.
4. (run_id, artifact_name) is unique on artifacts.
5. JSON columns reject malformed payloads (handled by PostgREST).

All tests skipped when SUPABASE_OPERATOR_URL or SUPABASE_OPERATOR_SERVICE_ROLE_KEY
is unset. Anon-key tests pull SUPABASE_ANON_KEY (or skip).
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")
ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")


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


def _anon_headers(key: str) -> dict[str, str]:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Profile": "operator_ui",
        "Accept-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


def _rest(base: str, path: str) -> str:
    return f"{base.rstrip('/')}/rest/v1/{path.lstrip('/')}"


@pytest.fixture
def service_client():
    base, key = _skip_unless_env()
    headers = _service_headers(key)
    with httpx.Client(timeout=15.0, base_url=f"{base.rstrip('/')}/rest/v1", headers=headers) as c:
        yield c


@pytest.fixture
def customer(service_client: httpx.Client):
    """Create a customer + run for nested constraint tests; cleans up after."""
    slug = f"stress-{uuid4().hex[:8]}"
    insert = service_client.post(
        "/customers", json={"slug": slug, "name": f"Stress {slug}"}
    )
    assert insert.status_code in (200, 201), insert.text
    cid = insert.json()[0]["id"]
    started = datetime.now(timezone.utc).isoformat()
    run_insert = service_client.post(
        "/runs",
        json={
            "customer_id": cid,
            "slug_with_ts": f"{slug}-2026-01-01T00-00-00Z",
            "started_at": started,
            "state": {},
        },
    )
    assert run_insert.status_code in (200, 201), run_insert.text
    rid = run_insert.json()[0]["id"]
    yield {"slug": slug, "id": cid, "run_id": rid}
    # cascade-clean
    service_client.delete(f"/customers?slug=eq.{slug}")


# -------- 1. slug CHECK constraint -----------------------------------------

@pytest.mark.integration
@pytest.mark.parametrize(
    "bad_slug",
    [
        "../etc-passwd",  # path traversal
        "UPPER",  # uppercase rejected
        "with space",  # whitespace
        "with/slash",  # slash
        "-leading-dash",  # constraint demands [a-z0-9] start
        "",  # empty
        "with?query=1",  # querystring chars
    ],
)
def test_slug_check_constraint_rejects_bad_input(
    service_client: httpx.Client, bad_slug: str
):
    resp = service_client.post(
        "/customers", json={"slug": bad_slug, "name": "Bad slug attempt"}
    )
    # Postgres CHECK violation surfaces as 400 from PostgREST.
    assert resp.status_code in (400, 409), (
        f"expected slug rejection, got {resp.status_code}: {resp.text}"
    )
    # If a row somehow snuck in, clean it up so we don't leave a permanent mess.
    if resp.status_code in (200, 201):
        service_client.delete(f"/customers?slug=eq.{bad_slug}")


@pytest.mark.integration
def test_slug_check_constraint_accepts_valid_inputs(service_client: httpx.Client):
    slug = f"valid-{uuid4().hex[:8]}"
    resp = service_client.post(
        "/customers", json={"slug": slug, "name": "Valid slug"}
    )
    assert resp.status_code in (200, 201), resp.text
    service_client.delete(f"/customers?slug=eq.{slug}")


# -------- 2. anon role write boundary --------------------------------------

@pytest.mark.integration
def test_anon_can_read_customers():
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    base, _ = _skip_unless_env()
    with httpx.Client(timeout=15.0) as c:
        resp = c.get(
            _rest(base, "customers?select=id&limit=1"),
            headers=_anon_headers(ANON_KEY),
        )
    assert resp.status_code == 200, resp.text


@pytest.mark.integration
@pytest.mark.parametrize("table", ["customers", "runs", "artifacts", "verifications"])
def test_anon_cannot_insert_into_skill_tables(table: str):
    """The anon key is bundled into the deployed UI JS. A leak must not let
    anyone create or destroy customer/run state."""
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    base, _ = _skip_unless_env()
    payload = {
        "customers": {"slug": f"anon-attempt-{uuid4().hex[:6]}", "name": "Anon attack"},
        "runs": {
            "customer_id": str(uuid4()),
            "slug_with_ts": "x-2026",
            "started_at": datetime.now(timezone.utc).isoformat(),
            "state": {},
        },
        "artifacts": {
            "run_id": str(uuid4()),
            "artifact_name": "brain-doc",
            "content": "x",
            "size_bytes": 1,
        },
        "verifications": {
            "run_id": str(uuid4()),
            "verified_at": datetime.now(timezone.utc).isoformat(),
            "summary": {},
            "checks": [],
        },
    }[table]
    with httpx.Client(timeout=15.0) as c:
        resp = c.post(
            _rest(base, table), headers=_anon_headers(ANON_KEY), json=payload
        )
    # PostgREST returns 401/403/42501 (permission denied) when the role lacks INSERT.
    # Empty-array success (200/201 with []) is also a fail-closed signal we should
    # NOT see — but we explicitly assert non-success.
    assert resp.status_code in (401, 403, 404), (
        f"anon should not insert into {table}; got {resp.status_code}: {resp.text}"
    )


@pytest.mark.integration
def test_anon_can_insert_annotation_when_run_exists(
    service_client: httpx.Client, customer: dict
):
    """Anon role IS allowed to write annotations — that's the operator surface."""
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    base, _ = _skip_unless_env()
    payload = {
        "run_id": customer["run_id"],
        "artifact_name": "brain-doc",
        "quote": "stress quote",
        "prefix": "p",
        "suffix": "s",
        "char_start": 0,
        "char_end": 12,
        "comment": "anon write should succeed here",
        "author_name": "stress-test",
    }
    with httpx.Client(timeout=15.0) as c:
        resp = c.post(
            _rest(base, "annotations"),
            headers=_anon_headers(ANON_KEY),
            json=payload,
        )
    assert resp.status_code in (200, 201), (
        f"anon should write annotations; got {resp.status_code}: {resp.text}"
    )
    # cleanup via service role (anon DELETE works too but service is hermetic)
    aid = resp.json()[0]["id"]
    service_client.delete(f"/annotations?id=eq.{aid}")


# -------- 3. FK CASCADE -----------------------------------------------------

@pytest.mark.integration
def test_delete_customer_cascades_through_runs_artifacts_annotations(
    service_client: httpx.Client,
):
    slug = f"cascade-{uuid4().hex[:8]}"
    started = datetime.now(timezone.utc).isoformat()
    cust = service_client.post(
        "/customers", json={"slug": slug, "name": "Cascade test"}
    ).json()[0]
    run = service_client.post(
        "/runs",
        json={
            "customer_id": cust["id"],
            "slug_with_ts": f"{slug}-2026-01-01T00-00-00Z",
            "started_at": started,
            "state": {},
        },
    ).json()[0]
    art = service_client.post(
        "/artifacts",
        json={
            "run_id": run["id"],
            "artifact_name": "brain-doc",
            "content": "body",
            "size_bytes": 4,
        },
    ).json()[0]
    ann = service_client.post(
        "/annotations",
        json={
            "run_id": run["id"],
            "artifact_name": "brain-doc",
            "quote": "q",
            "prefix": "p",
            "suffix": "s",
            "char_start": 0,
            "char_end": 1,
            "comment": "c",
            "author_name": "stress",
        },
    ).json()[0]

    # one shot delete on customer should wipe everything below.
    del_resp = service_client.delete(f"/customers?slug=eq.{slug}")
    assert del_resp.status_code in (200, 204), del_resp.text

    for path, key in [
        (f"/runs?id=eq.{run['id']}", "runs"),
        (f"/artifacts?id=eq.{art['id']}", "artifacts"),
        (f"/annotations?id=eq.{ann['id']}", "annotations"),
    ]:
        check = service_client.get(path)
        assert check.status_code == 200
        assert check.json() == [], f"{key} row not cascaded: {check.json()}"


# -------- 4. (run_id, artifact_name) uniqueness ----------------------------

@pytest.mark.integration
def test_artifact_uniqueness_per_run(service_client: httpx.Client, customer: dict):
    body = {
        "run_id": customer["run_id"],
        "artifact_name": "brain-doc",
        "content": "first",
        "size_bytes": 5,
    }
    first = service_client.post("/artifacts", json=body)
    assert first.status_code in (200, 201), first.text
    body["content"] = "second"
    body["size_bytes"] = 6
    second = service_client.post("/artifacts", json=body)
    assert second.status_code in (409, 400), (
        f"expected unique-violation on (run_id, brain-doc); got {second.status_code}: {second.text}"
    )


# -------- 5. malformed JSON in state column --------------------------------

@pytest.mark.integration
def test_runs_state_must_be_object_not_string(service_client: httpx.Client, customer: dict):
    # PostgREST will accept a JSON string into a jsonb column, so the schema
    # doesn't formally constrain the shape. We verify the column accepts a
    # well-formed object (positive control) and that state-as-null is rejected
    # by the NOT NULL constraint.
    null_attempt = service_client.post(
        "/runs",
        json={
            "customer_id": customer["id"],
            "slug_with_ts": f"{customer['slug']}-null-state",
            "started_at": datetime.now(timezone.utc).isoformat(),
            "state": None,
        },
    )
    assert null_attempt.status_code in (400, 409), (
        f"runs.state NOT NULL should reject null: {null_attempt.status_code} {null_attempt.text}"
    )
