"""Annotation flow stress tests (M6/M7).

Pre-M22 the browser UI wrote annotations directly via the anon key. M22
moved the surface behind Supabase Auth + an allowlist RLS policy, so anon
no longer has any write permission on operator_ui.* tables. These tests
now exercise the lifecycle as the operator UI does post-M22: against the
service-role key (bypassing RLS) for fixture setup. The auth-gated path
itself is covered by the `_authenticated_*` tests + the Playwright e2e
suite.

Skipped when SUPABASE_OPERATOR_URL / SUPABASE_OPERATOR_SERVICE_ROLE_KEY
are unset.
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
    """Returns (URL, service_key, anon_key_or_empty). Anon key is optional
    post-M22 — it's only used by the JWT-based auth tests."""
    if not (SUPABASE_URL and SERVICE_KEY):
        pytest.skip("Supabase env vars unset (URL / service).")
    return SUPABASE_URL, SERVICE_KEY, ANON_KEY or ""


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


def _make_annotation(rest: str, key: str, run_id: str, **overrides) -> dict:
    """Insert an annotation under whichever key the caller provides (service-
    role for fixtures, or a hand-minted authenticated JWT). Pre-M22 callers
    passed the anon key here — anon writes are now denied at the RLS layer."""
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
    with httpx.Client(timeout=15.0, headers=_hdr(key)) as c:
        resp = c.post(f"{rest}/annotations", json=payload)
    assert resp.status_code in (200, 201), resp.text
    return resp.json()[0]


@pytest.mark.integration
def test_full_lifecycle_open_resolved_deleted_restored(fixture_run):
    base, svc, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"

    ann = _make_annotation(rest, svc, fixture_run["run_id"])
    assert ann["status"] == "open"
    aid = ann["id"]

    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
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
    base, svc, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    ann = _make_annotation(
        rest, svc, fixture_run["run_id"], comment="status laundry list"
    )
    aid = ann["id"]
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
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
    base, svc, _ = _skip()
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
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
        r = c.post(f"{rest}/annotations", json=payload)
    assert r.status_code in (400, 409), (
        f"missing run_id should fail; got {r.status_code}: {r.text}"
    )


@pytest.mark.integration
def test_annotation_referencing_deleted_run_is_rejected(fixture_run):
    """FK enforcement on run_id — pointing at a non-existent run must fail."""
    base, svc, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    bogus = str(uuid4())
    with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
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


# -------- M22 — auth + RLS allowlist round-trips ---------------------------


@pytest.mark.integration
def test_authenticated_allowlist_user_can_read_and_write_annotations(fixture_run):
    """A JWT signed with SUPABASE_JWT_SECRET carrying email=leo@getspotfunnel.com
    must be able to read + write annotations end-to-end."""
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    from auth_helpers import authenticated_headers

    base, svc, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    headers = authenticated_headers("leo@getspotfunnel.com", ANON_KEY)
    payload = {
        "run_id": fixture_run["run_id"],
        "artifact_name": "brain-doc",
        "quote": "auth roundtrip",
        "prefix": "p",
        "suffix": "s",
        "char_start": 0,
        "char_end": 14,
        "comment": "auth-allowlist write should succeed",
        "author_email": "leo@getspotfunnel.com",
    }
    with httpx.Client(timeout=15.0, headers=headers) as c:
        ins = c.post(f"{rest}/annotations", json=payload)
    assert ins.status_code in (200, 201), (
        f"allowlist user write rejected: {ins.status_code} {ins.text}"
    )
    aid = ins.json()[0]["id"]
    try:
        with httpx.Client(timeout=15.0, headers=headers) as c:
            row = c.get(
                f"{rest}/annotations?id=eq.{aid}&select=id,author_email"
            )
            assert row.status_code == 200
            assert row.json()[0]["author_email"] == "leo@getspotfunnel.com"
    finally:
        with httpx.Client(timeout=15.0, headers=_hdr(svc)) as c:
            c.delete(f"{rest}/annotations?id=eq.{aid}")


@pytest.mark.integration
def test_authenticated_non_allowlist_user_is_denied(fixture_run):
    """A JWT for an email NOT on the allowlist must be denied by RLS."""
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    from auth_helpers import authenticated_headers

    base, _, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    headers = authenticated_headers("intruder@example.com", ANON_KEY)
    # Read: must return empty (RLS hides every row).
    with httpx.Client(timeout=15.0, headers=headers) as c:
        read = c.get(f"{rest}/annotations?select=id&limit=1")
    if read.status_code == 200:
        assert read.json() == [], (
            f"intruder JWT got data back: {read.json()!r}"
        )
    else:
        assert read.status_code in (401, 403), read.text

    # Write: must be rejected.
    payload = {
        "run_id": fixture_run["run_id"],
        "artifact_name": "brain-doc",
        "quote": "intruder",
        "prefix": "p",
        "suffix": "s",
        "char_start": 0,
        "char_end": 8,
        "comment": "should not land",
        "author_email": "intruder@example.com",
    }
    with httpx.Client(timeout=15.0, headers=headers) as c:
        ins = c.post(f"{rest}/annotations", json=payload)
    assert ins.status_code in (401, 403), (
        f"intruder JWT INSERT not blocked: {ins.status_code} {ins.text}"
    )


@pytest.mark.integration
def test_authenticated_user_cannot_impersonate_other_email(fixture_run):
    """Even an allowlisted user cannot insert claiming to be the OTHER
    allowlisted user — the auth_self_attribution policy enforces it."""
    if not ANON_KEY:
        pytest.skip("SUPABASE_ANON_KEY unset")
    from auth_helpers import authenticated_headers

    base, _, _ = _skip()
    rest = f"{base.rstrip('/')}/rest/v1"
    headers = authenticated_headers("leo@getspotfunnel.com", ANON_KEY)
    payload = {
        "run_id": fixture_run["run_id"],
        "artifact_name": "brain-doc",
        "quote": "impersonation",
        "prefix": "p",
        "suffix": "s",
        "char_start": 0,
        "char_end": 13,
        "comment": "leo claiming to be kye",
        "author_email": "kye@getspotfunnel.com",
    }
    with httpx.Client(timeout=15.0, headers=headers) as c:
        ins = c.post(f"{rest}/annotations", json=payload)
    assert ins.status_code in (401, 403), (
        f"impersonation NOT blocked: {ins.status_code} {ins.text}"
    )
