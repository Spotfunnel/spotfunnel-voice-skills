"""Integration test: round-trip a row through the operator_ui Postgres schema.

Talks to Supabase REST (PostgREST) using the service-role key.

Skipped automatically when SUPABASE_OPERATOR_URL or SUPABASE_OPERATOR_SERVICE_ROLE_KEY
is unset, so the test suite remains runnable in dev environments without secrets.
"""

from __future__ import annotations

import os
import re
from uuid import uuid4

import httpx
import pytest

SUPABASE_URL = os.environ.get("SUPABASE_OPERATOR_URL")
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY")

UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def _require_env() -> tuple[str, str]:
    """Return (url, key) or skip the test if either is missing."""
    if not SUPABASE_URL or not SERVICE_ROLE_KEY:
        pytest.skip(
            "SUPABASE_OPERATOR_URL and/or SUPABASE_OPERATOR_SERVICE_ROLE_KEY "
            "not set; skipping live Supabase round-trip test."
        )
    return SUPABASE_URL, SERVICE_ROLE_KEY


def _headers(key: str) -> dict[str, str]:
    """Standard headers for talking to the operator_ui schema via PostgREST."""
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Profile": "operator_ui",
        "Accept-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


def _customers_url(base: str) -> str:
    return f"{base.rstrip('/')}/rest/v1/customers"


@pytest.mark.integration
def test_customers_roundtrip_insert_read_delete():
    """Insert -> read -> delete -> verify-deleted on operator_ui.customers."""
    base, key = _require_env()
    headers = _headers(key)
    url = _customers_url(base)

    slug = f"test-{uuid4().hex[:8]}"
    name = f"Round-trip test {slug}"

    with httpx.Client(timeout=15.0) as client:
        # 1. Insert
        insert_resp = client.post(
            url,
            headers=headers,
            json={"slug": slug, "name": name},
        )
        assert insert_resp.status_code in (200, 201), (
            f"insert failed: {insert_resp.status_code} {insert_resp.text}"
        )
        inserted = insert_resp.json()
        assert isinstance(inserted, list) and len(inserted) == 1
        inserted_row = inserted[0]
        assert inserted_row["slug"] == slug
        assert inserted_row["name"] == name
        assert UUID_RE.match(inserted_row["id"]), (
            f"id is not a valid UUID: {inserted_row['id']!r}"
        )

        try:
            # 2. Read back
            read_resp = client.get(
                url,
                headers=headers,
                params={"slug": f"eq.{slug}", "select": "id,slug,name"},
            )
            assert read_resp.status_code == 200, (
                f"read failed: {read_resp.status_code} {read_resp.text}"
            )
            rows = read_resp.json()
            assert len(rows) == 1
            assert rows[0]["slug"] == slug
            assert rows[0]["id"] == inserted_row["id"]
            assert UUID_RE.match(rows[0]["id"])
        finally:
            # 3. Delete (always, even if a read assertion fails)
            delete_resp = client.delete(
                url,
                headers=headers,
                params={"slug": f"eq.{slug}"},
            )
            assert delete_resp.status_code in (200, 204), (
                f"delete failed: {delete_resp.status_code} {delete_resp.text}"
            )

        # 4. Verify gone
        verify_resp = client.get(
            url,
            headers=headers,
            params={"slug": f"eq.{slug}", "select": "id"},
        )
        assert verify_resp.status_code == 200
        assert verify_resp.json() == [], (
            f"row not deleted: {verify_resp.json()!r}"
        )
