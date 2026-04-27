#!/usr/bin/env bash
# scripts/review-list-lessons.sh
#
# Emit unpromoted lessons (promoted_to_prompt=false) as JSONL with maturity
# metadata for /base-agent review-feedback phase 2.
#
# Output schema (per line):
#   {"id": "L-...", "title": "...", "pattern": "...", "fix": "...",
#    "observed_in_customer_ids": ["uuid", ...],
#    "source_feedback_ids": ["F-...", ...],
#    "customer_count": N,
#    "created_at": "ISO",
#    "days_since_created": N,
#    "last_elevation_at": "ISO" | null,
#    "days_since_last_elevation": N | null,
#    "recommendation": "promote" | "keep"}
#
# Recommendation heuristic (from design doc): customer_count >= 3 AND
# days_since_last_elevation > 14 → promote. Otherwise keep. The orchestrator
# always defers to the operator's choice — this is just a hint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

LESSONS="$(supabase_get "lessons?promoted_to_prompt=eq.false&select=id,title,pattern,fix,observed_in_customer_ids,source_feedback_ids,created_at&order=created_at.asc")"

LESSON_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$LESSONS")"
if [ "$LESSON_COUNT" -eq 0 ]; then
  exit 0
fi

# Collect every source_feedback_id across all lessons so we can fetch their
# created_at in one round-trip and derive last_elevation_at per lesson.
ALL_FB_IDS_JSON="$(python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
ids = []
for r in rows:
    for fid in (r.get("source_feedback_ids") or []):
        if fid not in ids:
            ids.append(fid)
print(json.dumps(ids))
' "$LESSONS")"

ALL_FB_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$ALL_FB_IDS_JSON")"

if [ "$ALL_FB_COUNT" -gt 0 ]; then
  IN_FILTER="$(python3 -c '
import json, sys, urllib.parse
ids = json.loads(sys.argv[1])
inner = ",".join(urllib.parse.quote(i, safe="") for i in ids)
print(f"in.({inner})")
' "$ALL_FB_IDS_JSON")"
  FB_ROWS="$(supabase_get "feedback?id=${IN_FILTER}&select=id,created_at")"
else
  FB_ROWS="[]"
fi

python3 -c '
import json, sys
from datetime import datetime, timezone

lessons = json.loads(sys.argv[1] or "[]")
fb_rows = json.loads(sys.argv[2] or "[]")
fb_created = {r["id"]: r.get("created_at") for r in fb_rows}

now = datetime.now(timezone.utc)

def parse_ts(s):
    if not s:
        return None
    # Postgres returns "2026-04-25T12:34:56.789+00:00" or with "Z".
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None

def days_since(ts):
    if ts is None:
        return None
    d = (now - ts).total_seconds() / 86400.0
    return int(d)

for L in lessons:
    cust_ids = L.get("observed_in_customer_ids") or []
    fids = L.get("source_feedback_ids") or []
    created = parse_ts(L.get("created_at"))
    days_created = days_since(created)
    # last elevation = max(created_at) over the lessons source_feedback rows.
    last_elev = None
    for fid in fids:
        ts = parse_ts(fb_created.get(fid))
        if ts and (last_elev is None or ts > last_elev):
            last_elev = ts
    days_last = days_since(last_elev)
    cust_count = len(cust_ids)
    recommend = "keep"
    if cust_count >= 3 and days_last is not None and days_last > 14:
        recommend = "promote"
    out = {
        "id": L["id"],
        "title": L.get("title", ""),
        "pattern": L.get("pattern", ""),
        "fix": L.get("fix", ""),
        "observed_in_customer_ids": cust_ids,
        "source_feedback_ids": fids,
        "customer_count": cust_count,
        "created_at": L.get("created_at"),
        "days_since_created": days_created,
        "last_elevation_at": last_elev.isoformat() if last_elev else None,
        "days_since_last_elevation": days_last,
        "recommendation": recommend,
    }
    print(json.dumps(out, ensure_ascii=False))
' "$LESSONS" "$FB_ROWS"
