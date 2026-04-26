"""Annotation flow stress tests (M6/M7).

The browser UI writes annotations directly to Supabase using the anon key.
These tests simulate that surface and verify the full operator lifecycle:
create -> update status (resolve / reopen) -> soft-delete -> restore -> hard-delete
all work via anon, and that cross-run/cross-customer invariants hold.

Skipped when SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY /
SUPABASE_ANON_KEY are unset.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")
ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")


def _skip() -> tuple[str, str, str]:
    if not (SUPABASE_URL and SERVICE_KEY and ANON_KEY):
        pytest.skip("Supabase env vars unset (URL / service / anon).")
    return SUPABASE_URL, SERVICE_KEY, ANON_KEY


def _hdr(key: str) -> dict[str, str]:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
        "Content-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


@pytest.fixture
def fixture_run():
    base, svc, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    slug = f"ann-stress-{uuid4().hex[:8]}"
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
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
        try:
            yield {"slug": slug, "customer_id": cust["id"], "run_id": run["id"]}
        finally:
            c.delete(f"{rest}/customers?slug=eq.{slug}")


def _make_annotation(rest: str, anon: str, run_id: str, **overrides) -> dict:
    payload = {
        "run_id": run_id,
        "artifact_name": "brain-doc",
        "quote": "stress quote",
        "prefix": "p" * 40,
        "suffix": "s" * 40,
        "char_start": 100,
        "char_end": 112,
        "comment": "lifecycle stress",
        "author_name": "stress-test",
    }
    payload.update(overrides)
    with httpx.Client(timeout=15.0, headers=_hdr(anon)) as c:
        resp = c.post(f"{rest}/annotations", json=payload)
    assert resp.status_code in (200, 201), resp.text
    return resp.json()[0]


@pytest.mark.integration
def test_full_lifecycle_open_resolved_deleted_restored(fixture_run):
    base, _, anon = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"

    ann = _make_annotation(rest, anon, fixture_run["run_id"])
    assert ann["status"] == "open"
    aid = ann["id"]

    with httpx.Client(timeout=15.0, headers=_hdr(anon)) as c:
        # resolve
        r = c.patch(
            f"{rest}/annotations?id=eq.{aid}", json={"status": "resolved"}
        )
        assert r.status_code == 200, r.text
        assert r.json()[0]["status"] == "resolved"

        # reopen
        r = c.patch(f"{rest}/annotations?id=eq.{aid}", json={"status": "open"})
        assert r.status_code == 200
        assert r.json()[0]["status"] == "open"

        # soft-delete
        r = c.patch(f"{rest}/annotations?id=eq.{aid}", json={"status": "deleted"})
        assert r.status_code == 200
        assert r.json()[0]["status"] == "deleted"

        # restore
        r = c.patch(f"{rest}/annotations?id=eq.{aid}", json={"status": "open"})
        assert r.status_code == 200
        assert r.json()[0]["status"] == "open"

        # edit comment
        r = c.patch(
            f"{rest}/annotations?id=eq.{aid}", json={"comment": "edited via anon"}
        )
        assert r.status_code == 200
        assert r.json()[0]["comment"] == "edited via anon"

        # finally: hard delete
        r = c.delete(f"{rest}/annotations?id=eq.{aid}")
        assert r.status_code in (200, 204)


@pytest.mark.integration
def test_status_field_accepts_any_string(fixture_run):
    """Schema doesn't enforce a status enum — flag this so we know the field
    is freeform. If we add a CHECK constraint later, this test should flip
    to expect a 400. Until then, it documents the de-facto contract."""
    base, _, anon = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    ann = _make_annotation(
        rest, anon, fixture_run["run_id"], comment="status laundry list"
    )
    aid = ann["id"]
    with httpx.Client(timeout=15.0, headers=_hdr(anon)) as c:
        r = c.patch(
            f"{rest}/annotations?id=eq.{aid}", json={"status": "gibberish"}
        )
        # If this ever 400s, we tightened the schema — update test accordingly.
        assert r.status_code == 200, r.text
        assert r.json()[0]["status"] == "gibberish"
        c.delete(f"{rest}/annotations?id=eq.{aid}")


@pytest.mark.integration
def test_annotation_run_id_required(fixture_run):
    """run_id NOT NULL: a missing run_id must fail."""
    base, _, anon = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    payload = {
        "artifact_name": "brain-doc",
        "quote": "x",
        "prefix": "",
        "suffix": "",
        "char_start": 0,
        "char_end": 1,
        "comment": "missing run_id",
        "author_name": "stress-test",
    }
    with httpx.Client(timeout=15.0, headers=_hdr(anon)) as c:
        r = c.post(f"{rest}/annotations", json=payload)
    assert r.status_code in (400, 409), (
        f"missing run_id should fail; got {r.status_code}: {r.text}"
    )


@pytest.mark.integration
def test_annotation_referencing_deleted_run_is_rejected(fixture_run):
    """FK enforcement on run_id — pointing at a non-existent run must fail."""
    base, _, anon = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    bogus = str(uuid4())
    with httpx.Client(timeout=15.0, headers=_hdr(anon)) as c:
        r = c.post(
            f"{rest}/annotations",
            json={
                "run_id": bogus,
                "artifact_name": "brain-doc",
                "quote": "q",
                "prefix": "",
                "suffix": "",
                "char_start": 0,
                "char_end": 1,
                "comment": "bogus run_id",
                "author_name": "stress-test",
            },
        )
    assert r.status_code in (400, 409, 422), (
        f"FK violation expected; got {r.status_code}: {r.text}"
    )
