#!/usr/bin/env python3
"""Fetch unpromoted operator_ui.lessons rows and render them as a markdown block.

Used as a preamble at the top of /base-agent generator prompts (Stage 3, 4, 10)
so the orchestrator reads cross-customer corrections the operator has confirmed
but not yet baked into the prompt files themselves.

Behaviour:

- Reads SUPABASE_OPERATOR_URL + SUPABASE_OPERATOR_SERVICE_ROLE_KEY from env.
- Empty URL → silent exit 0 (developer running locally without Supabase).
- Empty result → empty stdout, exit 0.
- 500 / connection error → warning to stderr, exit 0 (lessons are advisory;
  a Supabase outage must not halt the skill).
- Connection errors / read timeouts retry once before giving up.

Run: python3 base-agent-setup/scripts/fetch_lessons.py
"""

from __future__ import annotations

import os
import sys
from typing import Iterable

import httpx

# Force UTF-8 output so em-dashes etc. render correctly when called from a
# Windows console with the default cp1252 stdout encoding.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except (AttributeError, OSError):
    pass

LESSONS_PATH = "/rest/v1/lessons"
SELECT = "id,title,pattern,fix"
FILTER = "promoted_to_prompt=eq.false"
ORDER = "order=created_at.asc"
TIMEOUT_S = 10.0


def _service_headers(key: str) -> dict[str, str]:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
        "Accept": "application/json",
    }


def _oneline(s: object) -> str:
    """Strip and collapse newlines to spaces. Trusted content otherwise."""
    return (s or "").strip().replace("\n", " ").replace("\r", " ")


def render_lessons(rows: Iterable[dict]) -> str:
    """Render lesson rows as the markdown block consumed by generator prompts.

    Empty input → empty string (caller wraps no special-casing).
    """
    rows = list(rows)
    if not rows:
        return ""
    lines = [
        "## Active lessons (cross-customer corrections, read first)",
        "",
        "The operator has confirmed these patterns across multiple customers. Honor them",
        "even when the surrounding prompt body doesn't mention the case.",
        "",
    ]
    for r in rows:
        lid = r.get("id", "L-???")
        # Strip embedded newlines — operators may paste multi-line `fix` text
        # from chat, and a stray \n would break the markdown bullet structure
        # and merge the next lesson into the prior bullet's italic block.
        title = _oneline(r.get("title"))
        pattern = _oneline(r.get("pattern"))
        fix = _oneline(r.get("fix"))
        lines.append(
            f"- **{lid} — {title}** _Pattern:_ {pattern} _Fix:_ {fix}"
        )
    lines.append("")
    lines.append("(End of active lessons.)")
    return "\n".join(lines)


def _fetch(url: str, headers: dict[str, str]) -> list[dict] | None:
    """One HTTP attempt. Returns rows on 200, None on any non-200."""
    with httpx.Client(timeout=TIMEOUT_S) as c:
        resp = c.get(url, headers=headers)
    if resp.status_code != 200:
        print(
            f"fetch_lessons: warning — Supabase returned {resp.status_code}; "
            f"continuing without lessons.",
            file=sys.stderr,
        )
        return None
    try:
        data = resp.json()
    except ValueError:
        print(
            "fetch_lessons: warning — Supabase response was not JSON; "
            "continuing without lessons.",
            file=sys.stderr,
        )
        return None
    if not isinstance(data, list):
        print(
            "fetch_lessons: warning — Supabase response wasn't a JSON list; "
            "continuing without lessons.",
            file=sys.stderr,
        )
        return None
    return data


def main() -> int:
    base = os.environ.get("SUPABASE_OPERATOR_URL", "").strip()
    key = os.environ.get("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "").strip()

    # Silent skip when no config is present at all — common dev case.
    if not base:
        return 0
    if not key:
        # Service-role key truly is required to read this schema; warn but exit 0.
        print(
            "fetch_lessons: warning — SUPABASE_OPERATOR_SERVICE_ROLE_KEY unset; "
            "continuing without lessons.",
            file=sys.stderr,
        )
        return 0

    url = f"{base.rstrip('/')}{LESSONS_PATH}?select={SELECT}&{FILTER}&{ORDER}"
    headers = _service_headers(key)

    rows: list[dict] | None = None
    last_error: Exception | None = None
    for attempt in range(2):  # one retry on transient network errors
        try:
            rows = _fetch(url, headers)
            break
        except (httpx.ConnectError, httpx.ReadTimeout) as exc:
            last_error = exc
            continue
        except httpx.HTTPError as exc:
            last_error = exc
            break

    if rows is None:
        if last_error is not None:
            print(
                f"fetch_lessons: warning — {type(last_error).__name__}: "
                f"{last_error}; continuing without lessons.",
                file=sys.stderr,
            )
        return 0

    block = render_lessons(rows)
    if block:
        print(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
