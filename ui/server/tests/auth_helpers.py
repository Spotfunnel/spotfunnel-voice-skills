"""Helpers for tests that need an authenticated allowlist user.

M22 introduced an RLS allowlist gate on `auth.jwt() ->> 'email'`. Tests that
previously used the anon key to write annotations now need either:

  (a) the service-role key (bypasses RLS — fastest, used for fixtures), or
  (b) a hand-minted JWT signed with SUPABASE_JWT_SECRET that carries
      email + role=authenticated, which Supabase's GoTrue accepts as a real
      session.

Both paths are exposed here. Tests should prefer (a) for setup/teardown and
(b) when they specifically need to verify the auth + RLS integration.
"""

from __future__ import annotations

import json
import os
import time
from typing import Optional

import pytest

JWT_SECRET = os.environ.get("SUPABASE_JWT_SECRET")


def _b64url(b: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def mint_user_jwt(
    email: str,
    *,
    secret: Optional[str] = None,
    expires_in: int = 3600,
    role: str = "authenticated",
) -> str:
    """Hand-roll an HS256 JWT matching the shape Supabase Auth emits.

    Returns a string suitable for `Authorization: Bearer <jwt>`. Skips the
    test (via pytest.skip) if SUPABASE_JWT_SECRET is missing — the surface
    is integration-only and there's no mocking story for the live REST API.
    """
    import hashlib
    import hmac

    secret = secret or JWT_SECRET
    if not secret:
        pytest.skip("SUPABASE_JWT_SECRET unset — skipping JWT-auth test")

    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "aud": "authenticated",
        "exp": now + expires_in,
        "iat": now,
        "iss": "supabase",
        "sub": email,  # close enough for RLS — we only key on email
        "email": email,
        "role": role,
    }
    h = _b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    p = _b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signing_input = f"{h}.{p}".encode("ascii")
    sig = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"


def authenticated_headers(email: str, anon_key: str) -> dict[str, str]:
    """Build PostgREST headers for an authenticated request as `email`.

    `apikey` is the project's anon key; `Authorization` is the user's JWT.
    PostgREST uses the JWT for RLS evaluation and falls back to the apikey
    role only for unauthenticated traffic.
    """
    jwt = mint_user_jwt(email)
    return {
        "apikey": anon_key,
        "Authorization": f"Bearer {jwt}",
        "Accept-Profile": "operator_ui",
        "Content-Profile": "operator_ui",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
