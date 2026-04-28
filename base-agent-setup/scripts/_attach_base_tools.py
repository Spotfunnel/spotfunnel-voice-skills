#!/usr/bin/env python3
"""Stage 6.5 — attach baseWarmTransfer + baseTakeMessage to a freshly-created
Ultravox agent + persist per-customer tool config to operator_ui.agent_tools.

Called by scripts/attach-base-tools.sh which validates env + dispatches.

Required env:
  SUPABASE_OPERATOR_URL, SUPABASE_OPERATOR_SERVICE_ROLE_KEY
  ULTRAVOX_API_KEY
  ULTRAVOX_BASE_TOOL_TRANSFER_ID, ULTRAVOX_BASE_TOOL_TAKE_MESSAGE_ID

Args:
  --slug <slug>                 customer slug
  --run-id <slug_with_ts>       run identifier (for deployment_log linkage)
  --agent-id <ultravox_agent_id> the live agent created at Stage 6
  --transfer-phone <e164>       single transfer destination (e.g. +61412345678)
  --message-email <email>       message recipient email

Halt rules:
  - missing/invalid argv → exit 1
  - missing tool IDs in env → exit 1 (operator setup gap)
  - Ultravox GET / PATCH non-2xx → exit 2 (HALT — caller is responsible
    for retry; deployment_log captures whatever made it through)
  - drift on a non-selectedTools field after PATCH → exit 2 (refuse to
    proceed; operator inspects)
  - Supabase write failures → exit 1 with detail; agent_tools rows that
    didn't land are detected by /base-agent verify's drift check

On success: prints a one-line summary + exit 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# Force UTF-8 output for Windows cp1252 consoles.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except (AttributeError, OSError):
    pass


# Server-side fields Ultravox mutates on every PATCH — ignore for drift.
_IGNORED_DRIFT_KEYS = {
    "updatedAt", "lastActiveTime", "lastModified", "modifiedAt",
    "lastUpdated", "lastActivityTime", "modified",
    "publishedRevisionId", "created", "updated", "createdAt",
}


def _http(method: str, url: str, headers: dict[str, str], body: dict | None = None) -> tuple[int, str]:
    data = None
    final_headers = dict(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        final_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=final_headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


def _op_url(path: str) -> str:
    return f"{os.environ['SUPABASE_OPERATOR_URL']}/rest/v1/{path}"


def _op_headers(write: bool = False) -> dict[str, str]:
    key = os.environ["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"]
    h = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "operator_ui",
        "Prefer": "return=representation",
    }
    if write:
        h["Content-Profile"] = "operator_ui"
    return h


def _ux_url(path: str) -> str:
    return f"https://api.ultravox.ai{path}"


def _ux_headers() -> dict[str, str]:
    return {"X-API-Key": os.environ["ULTRAVOX_API_KEY"], "Accept": "application/json"}


def _filter_drift(d: Any) -> Any:
    """Strip server-mutated fields recursively for drift comparison."""
    if isinstance(d, dict):
        return {k: _filter_drift(v) for k, v in d.items() if k not in _IGNORED_DRIFT_KEYS}
    if isinstance(d, list):
        return [_filter_drift(x) for x in d]
    return d


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--slug", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--agent-id", required=True)
    p.add_argument("--transfer-phone", required=True)
    p.add_argument("--message-email", required=True)
    args = p.parse_args(argv)

    # --- Validate env ---
    transfer_tool_id = os.environ.get("ULTRAVOX_BASE_TOOL_TRANSFER_ID", "").strip()
    take_message_tool_id = os.environ.get("ULTRAVOX_BASE_TOOL_TAKE_MESSAGE_ID", "").strip()
    if not transfer_tool_id or not take_message_tool_id:
        print(
            "[err] ULTRAVOX_BASE_TOOL_TRANSFER_ID and ULTRAVOX_BASE_TOOL_TAKE_MESSAGE_ID must be set in .env.\n"
            "      One-time operator setup: create the two shared tools in the Ultravox console, paste their IDs into .env.",
            file=sys.stderr,
        )
        return 1

    # --- Validate inputs ---
    phone = args.transfer_phone.strip()
    if not re.match(r"^\+61[2-478]\d{8}$", phone):
        print(f"[err] --transfer-phone must be E.164 AU (+61XXXXXXXXX), got: {phone}", file=sys.stderr)
        return 1
    email = args.message_email.strip().lower()
    if not re.match(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$", email):
        print(f"[err] --message-email is not a valid email address, got: {email}", file=sys.stderr)
        return 1

    # --- Resolve customer_id ---
    status, body = _http("GET", _op_url(f"customers?slug=eq.{urllib.parse.quote(args.slug)}&select=id"), _op_headers())
    if status >= 300:
        print(f"[err] customer lookup HTTP {status}: {body[:200]}", file=sys.stderr)
        return 1
    rows = json.loads(body)
    if not rows:
        print(f"[err] no customer row for slug '{args.slug}' — was Stage 1 reached?", file=sys.stderr)
        return 1
    customer_id = rows[0]["id"]

    # --- INSERT agent_tools rows (idempotent via upsert on conflict) ---
    transfer_config = {"destinations": [{"label": "primary", "phone": phone}]}
    take_message_config = {"recipient": {"channel": "email", "address": email}}

    rows_to_upsert = [
        {
            "customer_id": customer_id,
            "tool_name": "transfer",
            "config": transfer_config,
            "ultravox_tool_id": transfer_tool_id,
            "attached_to_agent_id": args.agent_id,
        },
        {
            "customer_id": customer_id,
            "tool_name": "take_message",
            "config": take_message_config,
            "ultravox_tool_id": take_message_tool_id,
            "attached_to_agent_id": args.agent_id,
        },
    ]
    status, body = _http(
        "POST",
        _op_url("agent_tools?on_conflict=customer_id,tool_name"),
        {**_op_headers(write=True),
         "Prefer": "return=representation,resolution=merge-duplicates"},
        rows_to_upsert,
    )
    if status >= 300:
        print(f"[err] agent_tools upsert HTTP {status}: {body[:200]}", file=sys.stderr)
        return 1
    inserted = json.loads(body)

    # --- GET agent (pre-snapshot for drift) ---
    status, body = _http("GET", _ux_url(f"/api/agents/{args.agent_id}"), _ux_headers())
    if status >= 300:
        print(f"[err] HALT: Ultravox GET agent HTTP {status}: {body[:300]}", file=sys.stderr)
        return 2
    agent = json.loads(body)
    pre = _filter_drift(agent)

    # --- Build new selectedTools ---
    new_tools = [
        {
            "toolId": transfer_tool_id,
            "nameOverride": "warmTransfer",
            "parameterOverrides": {"destination_phone": phone},
        },
        {
            "toolId": take_message_tool_id,
            "nameOverride": "takeMessage",
            "parameterOverrides": {
                "recipient_channel": "email",
                "recipient_address": email,
            },
        },
    ]

    # --- Build full PATCH body — full callTemplate copied forward, only selectedTools swapped ---
    call_template = dict(agent.get("callTemplate") or {})
    call_template["selectedTools"] = new_tools
    patch_body = {"callTemplate": call_template}

    status, body = _http(
        "PATCH",
        _ux_url(f"/api/agents/{args.agent_id}"),
        _ux_headers() | {"Content-Type": "application/json"},
        patch_body,
    )
    if status >= 300:
        print(f"[err] HALT: Ultravox PATCH agent HTTP {status}: {body[:300]}", file=sys.stderr)
        return 2

    # --- Drift check: GET again, filter drift-ignored, diff against pre except selectedTools ---
    status, body = _http("GET", _ux_url(f"/api/agents/{args.agent_id}"), _ux_headers())
    if status >= 300:
        print(f"[err] HALT: Ultravox post-PATCH GET HTTP {status}: {body[:300]}", file=sys.stderr)
        return 2
    post = _filter_drift(json.loads(body))

    # Compare every field except callTemplate.selectedTools.
    pre_ct = pre.get("callTemplate") or {}
    post_ct = post.get("callTemplate") or {}
    drift = []
    for k in set(pre_ct.keys()) | set(post_ct.keys()):
        if k == "selectedTools":
            continue
        if pre_ct.get(k) != post_ct.get(k):
            drift.append(f"callTemplate.{k}")
    for k in set(pre.keys()) | set(post.keys()):
        if k == "callTemplate":
            continue
        if pre.get(k) != post.get(k):
            drift.append(k)

    if drift:
        print(
            "[err] HALT: drift detected after PATCH. Fields changed unexpectedly: " + ", ".join(drift),
            file=sys.stderr,
        )
        return 2

    # --- log_deployment for each tool (so /base-agent remove can replay inverse) ---
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for row in inserted:
        log_args = [
            "bash",
            os.path.join(script_dir, "log_deployment.sh"),
            "--slug", args.slug,
            "--run-id", args.run_id,
            "--stage", "6",
            "--system", "supabase_operator_ui",
            "--action", "created",
            "--target-kind", "row",
            "--target-id", row["id"],
            "--payload", json.dumps({"table": "agent_tools", "tool_name": row["tool_name"], "agent_id": args.agent_id}),
            "--inverse-op", "delete",
            "--inverse-payload", json.dumps({"table": "agent_tools", "id": row["id"]}),
        ]
        try:
            subprocess.run(log_args, check=True, capture_output=True)
        except subprocess.CalledProcessError as e:
            # Don't halt — agent_tools rows are findable via drift detection
            # if logging is unreliable. Surface the warning.
            print(
                f"[warn] log_deployment failed for agent_tools row {row['id']}: "
                f"{e.stderr.decode('utf-8', 'replace')[:200]}",
                file=sys.stderr,
            )

    print(
        f"[ok] base tools attached to agent {args.agent_id}: "
        f"transfer→{phone}, take_message→{email}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
