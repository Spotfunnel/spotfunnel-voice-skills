#!/usr/bin/env python3
"""scripts/_remove_customer.py — full teardown of a /base-agent customer.

Reads operator_ui.deployment_log entries for the slug + live-queries every
external system the creation flow touches. Surfaces a unified inventory,
asks for confirmation, then replays inverse operations newest-first.

Halt rules:
  - Telnyx pool restoration failure → HALT (ingress would still ring).
  - Ultravox agent DELETE failure → HALT (ingress would still resolve).
  - Everything else (operator_ui rows, dashboard rows, lessons surgical
    edit, local FS) → best-effort + log + summarize.

Usage (from remove-customer.sh):
  python3 scripts/_remove_customer.py <slug> [--dry-run] [--yes] [--verbose]

Env required (source via env-check.sh first):
  SUPABASE_OPERATOR_URL, SUPABASE_OPERATOR_SERVICE_ROLE_KEY
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (dashboard schema; same project)
  TELNYX_API_KEY
  ULTRAVOX_API_KEY
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Windows console default codepage (cp1252) can't encode ✓ ✗ —. Force UTF-8
# so the inventory + summary tables render correctly across platforms.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except (AttributeError, OSError):
    pass


# ---------------------------------------------------------------------------
# HTTP helpers (no external deps; --ssl-no-revoke equivalent unavailable in
# urllib so we accept that Windows SChannel revocation may occasionally
# false-positive — operator can fall back to direct curl in that case)
# ---------------------------------------------------------------------------


class HttpError(Exception):
    def __init__(self, status: int, body: str, url: str) -> None:
        super().__init__(f"HTTP {status} on {url}: {body[:300]}")
        self.status = status
        self.body = body


def http_request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> tuple[int, str]:
    data = None
    final_headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        final_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=final_headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


# ---------------------------------------------------------------------------
# Supabase REST clients (operator_ui + dashboard schemas)
# ---------------------------------------------------------------------------


def supa_op_headers() -> dict[str, str]:
    key = os.environ["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"]
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
        "Content-Profile": "operator_ui",
        "Prefer": "return=representation",
    }


def supa_op_url(path: str) -> str:
    return f"{os.environ['SUPABASE_OPERATOR_URL']}/rest/v1/{path}"


def op_get(path: str) -> list[dict[str, Any]]:
    status, body = http_request("GET", supa_op_url(path), supa_op_headers())
    if status >= 300:
        raise HttpError(status, body, path)
    return json.loads(body)


def op_patch(path: str, payload: dict[str, Any]) -> list[dict[str, Any]]:
    status, body = http_request("PATCH", supa_op_url(path), supa_op_headers(), payload)
    if status >= 300:
        raise HttpError(status, body, path)
    return json.loads(body)


def op_delete(path: str) -> list[dict[str, Any]]:
    status, body = http_request("DELETE", supa_op_url(path), supa_op_headers())
    if status >= 300:
        raise HttpError(status, body, path)
    return json.loads(body) if body.strip() else []


def supa_dash_headers() -> dict[str, str]:
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Prefer": "return=representation",
    }


def supa_dash_url(path: str) -> str:
    return f"{os.environ['SUPABASE_URL']}/rest/v1/{path}"


def dash_get(path: str) -> list[dict[str, Any]]:
    if not os.environ.get("SUPABASE_URL"):
        return []
    status, body = http_request("GET", supa_dash_url(path), supa_dash_headers())
    if status >= 300:
        raise HttpError(status, body, path)
    return json.loads(body)


def dash_delete(path: str) -> list[dict[str, Any]]:
    status, body = http_request("DELETE", supa_dash_url(path), supa_dash_headers())
    if status >= 300:
        raise HttpError(status, body, path)
    return json.loads(body) if body.strip() else []


def dash_auth_admin_delete(user_id: str) -> None:
    url = f"{os.environ['SUPABASE_URL']}/auth/v1/admin/users/{user_id}"
    status, body = http_request("DELETE", url, supa_dash_headers())
    if status >= 300 and status != 404:
        raise HttpError(status, body, url)


# ---------------------------------------------------------------------------
# Inventory + plan
# ---------------------------------------------------------------------------


@dataclass
class Inventory:
    log_rows: list[dict[str, Any]] = field(default_factory=list)
    op_customer: dict[str, Any] | None = None
    op_runs: list[dict[str, Any]] = field(default_factory=list)
    op_artifacts: list[dict[str, Any]] = field(default_factory=list)
    op_annotations: list[dict[str, Any]] = field(default_factory=list)
    op_feedback: list[dict[str, Any]] = field(default_factory=list)
    op_verifications: list[dict[str, Any]] = field(default_factory=list)
    op_lessons_touching: list[dict[str, Any]] = field(default_factory=list)
    op_agent_tools: list[dict[str, Any]] = field(default_factory=list)
    dash_workspace: dict[str, Any] | None = None
    dash_users: list[dict[str, Any]] = field(default_factory=list)
    dash_calls_count: int = 0
    dash_workflow_errors_count: int = 0
    telnyx_apps: list[dict[str, Any]] = field(default_factory=list)
    ultravox_agents: list[dict[str, Any]] = field(default_factory=list)
    local_run_dirs: list[Path] = field(default_factory=list)


def discover(slug: str) -> Inventory:
    inv = Inventory()

    # --- deployment_log ----------------------------------------------------
    inv.log_rows = op_get(
        f"deployment_log?customer_slug=eq.{urllib.parse.quote(slug)}"
        f"&status=eq.active&order=created_at.desc"
    )

    # --- operator_ui rows --------------------------------------------------
    cust = op_get(f"customers?slug=eq.{urllib.parse.quote(slug)}&select=id,slug,name")
    if cust:
        inv.op_customer = cust[0]
        cid = inv.op_customer["id"]
        inv.op_runs = op_get(f"runs?customer_id=eq.{cid}&select=id,slug_with_ts,started_at")
        run_ids = [r["id"] for r in inv.op_runs]
        if run_ids:
            ids_filter = ",".join(f'"{r}"' for r in run_ids)
            inv.op_artifacts = op_get(
                f"artifacts?run_id=in.({ids_filter})&select=id,artifact_name,run_id"
            )
            inv.op_annotations = op_get(
                f"annotations?run_id=in.({ids_filter})&select=id,run_id,artifact_name,status"
            )
            inv.op_verifications = op_get(
                f"verifications?run_id=in.({ids_filter})&select=id,run_id"
            )
        inv.op_feedback = op_get(
            f"feedback?customer_id=eq.{cid}&select=id,artifact_name,status"
        )
        # Lessons touching this customer (array contains).
        # PostgREST `cs` (contains) operator on uuid[] column.
        inv.op_lessons_touching = op_get(
            f"lessons?observed_in_customer_ids=cs.{{{cid}}}"
            f"&select=id,title,observed_in_customer_ids,source_feedback_ids,promoted_to_prompt"
        )
        # Base-tools rows (Stage 6.5 of /base-agent). Empty for existing
        # per-customer-server installs; a couple of rows for new customers.
        # CASCADE on customer_id means the subsequent customers DELETE will
        # auto-clean these — but discovery + verification still report them
        # for transparency.
        inv.op_agent_tools = op_get(
            f"agent_tools?customer_id=eq.{cid}"
            f"&select=id,tool_name,attached_to_agent_id"
        )

    # --- dashboard rows ----------------------------------------------------
    # If SUPABASE_URL points at a project without the dashboard schema (e.g.
    # the operator_ui project itself, while a real prod dashboard hasn't been
    # provisioned yet), workspaces lookup 404s with PGRST205 — silently skip.
    # Any OTHER dashboard error still bubbles a warning.
    if os.environ.get("SUPABASE_URL"):
        try:
            ws = dash_get(
                f"workspaces?slug=eq.{urllib.parse.quote(slug)}&select=id,slug,name"
            )
            if ws:
                inv.dash_workspace = ws[0]
                wid = inv.dash_workspace["id"]
                inv.dash_users = dash_get(
                    f"users?workspace_id=eq.{wid}&select=id,email,name,role"
                )
                calls = dash_get(f"calls?workspace_id=eq.{wid}&select=id")
                inv.dash_calls_count = len(calls)
                wfe = dash_get(f"workflow_errors?workspace_id=eq.{wid}&select=id")
                inv.dash_workflow_errors_count = len(wfe)
        except HttpError as e:
            if e.status == 404 and "PGRST205" in e.body:
                pass  # dashboard schema not provisioned in this Supabase project — expected
            else:
                print(
                    f"[warn] dashboard discovery failed (HTTP {e.status}) — continuing "
                    f"with operator_ui-only inventory. Detail: {e.body[:200]}",
                    file=sys.stderr,
                )

    # --- Telnyx claimed-{slug} apps ---------------------------------------
    inv.telnyx_apps = telnyx_list_claimed(slug)

    # --- Ultravox agents matching slug pattern -----------------------------
    inv.ultravox_agents = ultravox_list_matching_slug(slug)

    # --- Local run-dirs ----------------------------------------------------
    runs_root = Path(__file__).resolve().parent.parent / "runs"
    if runs_root.is_dir():
        prefix = f"{slug}-"
        inv.local_run_dirs = sorted(
            d for d in runs_root.iterdir() if d.is_dir() and d.name.startswith(prefix)
        )

    return inv


def telnyx_list_claimed(slug: str) -> list[dict[str, Any]]:
    """List TeXML apps tagged claimed-{slug}."""
    key = os.environ.get("TELNYX_API_KEY")
    if not key:
        return []
    headers = {"Authorization": f"Bearer {key}"}
    apps_url = "https://api.telnyx.com/v2/texml_applications?page[size]=250"
    status, body = http_request("GET", apps_url, headers)
    if status >= 300:
        print(f"[warn] Telnyx list TeXML apps failed HTTP {status}: {body[:200]}", file=sys.stderr)
        return []
    data = json.loads(body).get("data", [])
    claim_tag = f"claimed-{slug}"
    return [a for a in data if claim_tag in (a.get("tags") or [])]


def telnyx_get_app(app_id: str) -> dict[str, Any] | None:
    key = os.environ["TELNYX_API_KEY"]
    headers = {"Authorization": f"Bearer {key}"}
    status, body = http_request(
        "GET", f"https://api.telnyx.com/v2/texml_applications/{app_id}", headers
    )
    if status >= 300:
        return None
    return json.loads(body).get("data")


def ultravox_list_matching_slug(slug: str) -> list[dict[str, Any]]:
    """Find Ultravox agents whose name contains a CamelCased version of the slug.

    Heuristic: name pattern is "{Customer}-{AgentFirstName}" with no spaces.
    Slug is lowercase-hyphenated. Match is best-effort: we strip hyphens on
    both sides and check substring match. Returns all that match.
    """
    key = os.environ.get("ULTRAVOX_API_KEY")
    if not key:
        return []
    headers = {"X-API-Key": key, "Accept": "application/json"}
    slug_compact = slug.replace("-", "").lower()
    matches: list[dict[str, Any]] = []
    cursor = ""
    pages = 0
    while pages < 10:
        pages += 1
        url = "https://api.ultravox.ai/api/agents?pageSize=50"
        if cursor:
            url += f"&cursor={urllib.parse.quote(cursor)}"
        status, body = http_request("GET", url, headers)
        if status >= 300:
            print(
                f"[warn] Ultravox list agents failed HTTP {status}: {body[:200]}",
                file=sys.stderr,
            )
            return matches
        page = json.loads(body)
        for a in page.get("results") or page.get("data") or []:
            name = (a.get("name") or "").lower().replace("-", "")
            if slug_compact in name:
                matches.append(a)
        cursor = page.get("nextCursor") or ""
        if not cursor:
            break
    return matches


# ---------------------------------------------------------------------------
# Inventory printing
# ---------------------------------------------------------------------------


def fmt_count(n: int) -> str:
    return f"{n} row" if n == 1 else f"{n} rows"


def print_inventory(slug: str, inv: Inventory) -> None:
    print()
    print(f"Discovered traces for \"{slug}\":")
    print(f"  deployment_log entries (active)   {fmt_count(len(inv.log_rows))}")
    print(f"  operator_ui.customers             {'1 row (' + inv.op_customer['id'] + ')' if inv.op_customer else '0 rows'}")
    print(f"  operator_ui.runs                  {fmt_count(len(inv.op_runs))}")
    print(f"  operator_ui.artifacts             {fmt_count(len(inv.op_artifacts))}")
    print(f"  operator_ui.annotations           {fmt_count(len(inv.op_annotations))}")
    print(f"  operator_ui.feedback              {fmt_count(len(inv.op_feedback))}")
    print(f"  operator_ui.verifications         {fmt_count(len(inv.op_verifications))}")
    print(f"  operator_ui.lessons (touching)    {fmt_count(len(inv.op_lessons_touching))}  (surgical scrub)")
    print(f"  operator_ui.agent_tools           {fmt_count(len(inv.op_agent_tools))}  (CASCADE on customer delete)")
    if inv.dash_workspace:
        print(f"  dashboard.workspaces              1 row ({inv.dash_workspace['id']})")
        print(f"  dashboard.public.users            {fmt_count(len(inv.dash_users))}")
        print(f"  dashboard.calls                   {fmt_count(inv.dash_calls_count)}")
        print(f"  dashboard.workflow_errors         {fmt_count(inv.dash_workflow_errors_count)}")
    else:
        print(f"  dashboard.workspaces              0 rows")
    print(f"  Telnyx claimed-{slug} apps        {len(inv.telnyx_apps)} app(s)")
    for a in inv.telnyx_apps:
        print(f"    - app_id={a.get('id')} friendly_name={a.get('friendly_name')!r}")
    print(f"  Ultravox agents (slug-matched)    {len(inv.ultravox_agents)} agent(s)")
    for a in inv.ultravox_agents:
        aid = a.get("agentId") or a.get("id")
        print(f"    - id={aid} name={a.get('name')!r}")
    print(f"  Local run-dirs                    {len(inv.local_run_dirs)} dir(s)")
    for d in inv.local_run_dirs:
        print(f"    - {d}")

    # Drift detection — items in reality NOT covered by log entries.
    drift = compute_drift(inv)
    if drift:
        print()
        print("⚠  Drift detected — these items exist in reality but have no log entry:")
        for line in drift:
            print(f"   - {line}")
        print("   They will still be deleted via live-discovery teardown.")


def compute_drift(inv: Inventory) -> list[str]:
    """Identify items in reality NOT covered by deployment_log."""
    logged_target_ids = {row.get("target_id") for row in inv.log_rows if row.get("target_id")}
    drift: list[str] = []

    if inv.op_customer and inv.op_customer["id"] not in logged_target_ids:
        drift.append(f"operator_ui.customers row {inv.op_customer['id']} (no log entry)")
    for r in inv.op_runs:
        if r["id"] not in logged_target_ids:
            drift.append(f"operator_ui.runs row {r['id']} ({r.get('slug_with_ts')})")
    for a in inv.op_artifacts:
        if a["id"] not in logged_target_ids:
            drift.append(f"operator_ui.artifacts row {a['id']} ({a.get('artifact_name')})")
    for a in inv.telnyx_apps:
        if a.get("id") not in logged_target_ids:
            drift.append(f"Telnyx TeXML app {a.get('id')}")
    for a in inv.ultravox_agents:
        aid = a.get("agentId") or a.get("id")
        if aid not in logged_target_ids:
            drift.append(f"Ultravox agent {aid} ({a.get('name')})")
    return drift


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------


@dataclass
class StepResult:
    step: str
    target: str
    ok: bool
    error: str | None = None
    skipped: bool = False


def teardown(slug: str, inv: Inventory, dry_run: bool) -> list[StepResult]:
    results: list[StepResult] = []

    # --- Phase A: Telnyx (HALT on failure) --------------------------------
    for app in inv.telnyx_apps:
        app_id = app.get("id")
        if not app_id:
            continue
        if dry_run:
            results.append(StepResult("telnyx.untag_repool", app_id, ok=True, skipped=True))
            continue
        try:
            telnyx_untag_repool(app_id, slug)
            results.append(StepResult("telnyx.untag_repool", app_id, ok=True))
            mark_log_reversed_by_target(slug, app_id)
        except Exception as e:
            results.append(StepResult("telnyx.untag_repool", app_id, ok=False, error=str(e)))
            mark_log_reverse_failed_by_target(slug, app_id, str(e))
            print_phase_summary(results)
            print(f"\n✗ HALT: Telnyx pool restoration failed for app {app_id}. Re-run after fixing.", file=sys.stderr)
            sys.exit(2)

    # --- Phase B: Ultravox (HALT on failure) ------------------------------
    for agent in inv.ultravox_agents:
        aid = agent.get("agentId") or agent.get("id")
        if not aid:
            continue
        if dry_run:
            results.append(StepResult("ultravox.delete_agent", aid, ok=True, skipped=True))
            continue
        try:
            ultravox_delete_agent(aid)
            results.append(StepResult("ultravox.delete_agent", aid, ok=True))
            mark_log_reversed_by_target(slug, aid)
        except Exception as e:
            results.append(StepResult("ultravox.delete_agent", aid, ok=False, error=str(e)))
            mark_log_reverse_failed_by_target(slug, aid, str(e))
            print_phase_summary(results)
            print(f"\n✗ HALT: Ultravox DELETE failed for agent {aid}. Re-run after fixing.", file=sys.stderr)
            sys.exit(2)

    # --- Phase C: Dashboard (best-effort) ---------------------------------
    if inv.dash_workspace and not dry_run:
        wid = inv.dash_workspace["id"]
        # auth.users via admin API
        for u in inv.dash_users:
            try:
                dash_auth_admin_delete(u["id"])
                results.append(StepResult("dashboard.auth.users", u["id"], ok=True))
            except Exception as e:
                results.append(StepResult("dashboard.auth.users", u["id"], ok=False, error=str(e)))
        # public.users (CASCADE may have already done some)
        try:
            dash_delete(f"users?workspace_id=eq.{wid}")
            results.append(StepResult("dashboard.public.users", f"workspace_id={wid}", ok=True))
        except Exception as e:
            results.append(StepResult("dashboard.public.users", f"workspace_id={wid}", ok=False, error=str(e)))
        # calls
        try:
            dash_delete(f"calls?workspace_id=eq.{wid}")
            results.append(StepResult("dashboard.calls", f"workspace_id={wid}", ok=True))
        except Exception as e:
            results.append(StepResult("dashboard.calls", f"workspace_id={wid}", ok=False, error=str(e)))
        # workflow_errors
        try:
            dash_delete(f"workflow_errors?workspace_id=eq.{wid}")
            results.append(StepResult("dashboard.workflow_errors", f"workspace_id={wid}", ok=True))
        except Exception as e:
            results.append(StepResult("dashboard.workflow_errors", f"workspace_id={wid}", ok=False, error=str(e)))
        # workspace itself
        try:
            dash_delete(f"workspaces?id=eq.{wid}")
            results.append(StepResult("dashboard.workspaces", wid, ok=True))
        except Exception as e:
            results.append(StepResult("dashboard.workspaces", wid, ok=False, error=str(e)))

    # --- Phase D: operator_ui surgical edits + bulk deletes ---------------
    if not dry_run and inv.op_customer:
        cid = inv.op_customer["id"]

        # Lessons surgical scrub
        for lesson in inv.op_lessons_touching:
            try:
                lesson_surgical_scrub(lesson, cid, inv.op_feedback)
                results.append(StepResult("operator_ui.lessons.scrub", lesson["id"], ok=True))
            except Exception as e:
                results.append(StepResult("operator_ui.lessons.scrub", lesson["id"], ok=False, error=str(e)))

        # Bulk deletes — children first (FK-safe even without cascade).
        for table_query, label in [
            (f"verifications?run_id=in.({_run_ids_filter(inv.op_runs)})", "verifications"),
            (f"feedback?customer_id=eq.{cid}", "feedback"),
            (f"annotations?run_id=in.({_run_ids_filter(inv.op_runs)})", "annotations"),
            (f"artifacts?run_id=in.({_run_ids_filter(inv.op_runs)})", "artifacts"),
            (f"runs?customer_id=eq.{cid}", "runs"),
            (f"customers?id=eq.{cid}", "customers"),
        ]:
            if "in.()" in table_query:
                # No runs — skip the dependent-row deletes entirely.
                results.append(StepResult(f"operator_ui.{label}", "no rows", ok=True, skipped=True))
                continue
            try:
                op_delete(table_query)
                results.append(StepResult(f"operator_ui.{label}", "deleted", ok=True))
            except Exception as e:
                results.append(StepResult(f"operator_ui.{label}", "deleted", ok=False, error=str(e)))

        # Mark every remaining log entry for this slug as reversed.
        try:
            op_patch(
                f"deployment_log?customer_slug=eq.{urllib.parse.quote(slug)}&status=eq.active",
                {"status": "reversed", "reversed_at": now_iso()},
            )
        except Exception as e:
            print(f"[warn] failed to mark deployment_log entries as reversed: {e}", file=sys.stderr)

    # --- Phase E: Local FS (best-effort) ----------------------------------
    if not dry_run:
        for d in inv.local_run_dirs:
            try:
                shutil.rmtree(d)
                results.append(StepResult("local_fs.rm", str(d), ok=True))
            except Exception as e:
                results.append(StepResult("local_fs.rm", str(d), ok=False, error=str(e)))

    return results


def telnyx_untag_repool(app_id: str, slug: str) -> None:
    """Drop claimed-{slug} tag, ensure pool-available stays, clear voice_url
    and any TeXML wiring set in Stages 8/9. Restores the app to clean
    pool-available state."""
    key = os.environ["TELNYX_API_KEY"]
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    cur = telnyx_get_app(app_id)
    if cur is None:
        raise RuntimeError(f"Telnyx GET app {app_id} returned no body")
    cur_tags = cur.get("tags") or []
    new_tags = [t for t in cur_tags if t != f"claimed-{slug}"]
    if "pool-available" not in new_tags:
        new_tags.append("pool-available")
    payload = {
        "tags": new_tags,
        "voice_url": "",
        "voice_method": "POST",
        "voice_fallback_url": "",
        "status_callback": "",
    }
    status, body = http_request(
        "PATCH",
        f"https://api.telnyx.com/v2/texml_applications/{app_id}",
        headers,
        payload,
    )
    if status >= 300:
        raise HttpError(status, body, f"telnyx PATCH {app_id}")


def ultravox_delete_agent(agent_id: str) -> None:
    key = os.environ["ULTRAVOX_API_KEY"]
    headers = {"X-API-Key": key}
    status, body = http_request(
        "DELETE", f"https://api.ultravox.ai/api/agents/{agent_id}", headers
    )
    if status not in (200, 202, 204) and status != 404:
        raise HttpError(status, body, f"ultravox DELETE {agent_id}")


def lesson_surgical_scrub(
    lesson: dict[str, Any], customer_id: str, customer_feedback: list[dict[str, Any]]
) -> None:
    """Remove customer_id from observed_in_customer_ids and remove this
    customer's feedback ids from source_feedback_ids. If both end empty AND
    promoted_to_prompt=false → DELETE the row (orphan lesson). Promoted
    lessons are kept regardless because the prompt file change is git-tracked.
    """
    new_observed = [c for c in lesson.get("observed_in_customer_ids") or [] if c != customer_id]
    customer_feedback_ids = {f["id"] for f in customer_feedback}
    new_sources = [
        s for s in lesson.get("source_feedback_ids") or [] if s not in customer_feedback_ids
    ]
    if not new_observed and not new_sources and not lesson.get("promoted_to_prompt"):
        op_delete(f"lessons?id=eq.{lesson['id']}")
        return
    op_patch(
        f"lessons?id=eq.{lesson['id']}",
        {
            "observed_in_customer_ids": new_observed,
            "source_feedback_ids": new_sources,
        },
    )


def _run_ids_filter(runs: list[dict[str, Any]]) -> str:
    if not runs:
        return ""
    return ",".join(f'"{r["id"]}"' for r in runs)


def now_iso() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).isoformat()


def mark_log_reversed_by_target(slug: str, target_id: str) -> None:
    try:
        op_patch(
            f"deployment_log?customer_slug=eq.{urllib.parse.quote(slug)}"
            f"&target_id=eq.{urllib.parse.quote(target_id)}&status=eq.active",
            {"status": "reversed", "reversed_at": now_iso()},
        )
    except Exception as e:
        print(f"[warn] failed to mark log row reversed (target={target_id}): {e}", file=sys.stderr)


def mark_log_reverse_failed_by_target(slug: str, target_id: str, err: str) -> None:
    try:
        op_patch(
            f"deployment_log?customer_slug=eq.{urllib.parse.quote(slug)}"
            f"&target_id=eq.{urllib.parse.quote(target_id)}&status=eq.active",
            {"status": "reverse_failed", "reverse_error": err[:500]},
        )
    except Exception:
        pass  # nothing to do; original error is already being surfaced


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(slug: str) -> tuple[bool, list[str]]:
    """Re-run discovery and report any residue."""
    inv = discover(slug)
    residue: list[str] = []
    if inv.op_customer:
        residue.append(f"operator_ui.customers: {inv.op_customer['id']} still present")
    if inv.op_runs:
        residue.append(f"operator_ui.runs: {len(inv.op_runs)} rows still present")
    if inv.op_artifacts:
        residue.append(f"operator_ui.artifacts: {len(inv.op_artifacts)} rows still present")
    if inv.op_annotations:
        residue.append(f"operator_ui.annotations: {len(inv.op_annotations)} rows")
    if inv.op_feedback:
        residue.append(f"operator_ui.feedback: {len(inv.op_feedback)} rows")
    if inv.op_verifications:
        residue.append(f"operator_ui.verifications: {len(inv.op_verifications)} rows")
    if inv.op_agent_tools:
        residue.append(f"operator_ui.agent_tools: {len(inv.op_agent_tools)} rows")
    if inv.dash_workspace:
        residue.append(f"dashboard.workspaces: {inv.dash_workspace['id']} still present")
    if inv.telnyx_apps:
        residue.append(f"Telnyx claimed-{slug}: {len(inv.telnyx_apps)} apps still tagged")
    if inv.ultravox_agents:
        residue.append(f"Ultravox: {len(inv.ultravox_agents)} agents still present")
    if inv.local_run_dirs:
        residue.append(f"local FS: {len(inv.local_run_dirs)} run-dirs still present")
    return (not residue), residue


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def print_phase_summary(results: list[StepResult]) -> None:
    if not results:
        return
    print()
    print("Teardown summary:")
    for r in results:
        status_glyph = "·" if r.skipped else ("✓" if r.ok else "✗")
        line = f"  {status_glyph} {r.step:32s} {r.target}"
        if r.error:
            line += f"   error: {r.error[:120]}"
        if r.skipped:
            line += "   (dry-run)"
        print(line)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Tear down a /base-agent customer.")
    p.add_argument("slug")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--yes", "-y", action="store_true", help="Skip confirmation prompt")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args(argv)

    if not re.match(r"^[a-z0-9][a-z0-9-]*$", args.slug):
        print(f"[err] invalid slug format: {args.slug}", file=sys.stderr)
        return 1

    print(f"\n/base-agent remove — slug: {args.slug}{' (dry-run)' if args.dry_run else ''}")
    inv = discover(args.slug)
    print_inventory(args.slug, inv)

    is_empty = (
        not inv.log_rows
        and not inv.op_customer
        and not inv.op_runs
        and not inv.op_artifacts
        and not inv.dash_workspace
        and not inv.telnyx_apps
        and not inv.ultravox_agents
        and not inv.local_run_dirs
    )
    if is_empty:
        print(f"\n✓ Nothing to remove for slug \"{args.slug}\".")
        return 0

    if args.dry_run:
        print("\n--dry-run: would tear down everything above. Exiting without changes.")
        return 0

    if not args.yes:
        print()
        try:
            ans = input("Delete all of the above? (y/N) ").strip().lower()
        except EOFError:
            ans = ""
        if ans != "y":
            print("Aborted.")
            return 1

    results = teardown(args.slug, inv, dry_run=False)
    print_phase_summary(results)

    print("\nVerifying zero residue …")
    ok, residue = verify(args.slug)
    if ok:
        print(f"✓ Verified: zero traces remaining for \"{args.slug}\".")
        return 0 if all(r.ok or r.skipped for r in results) else 1
    print("✗ Residue found:")
    for line in residue:
        print(f"  - {line}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
