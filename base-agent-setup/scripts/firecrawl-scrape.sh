#!/bin/bash
# scripts/firecrawl-scrape.sh
#
# Crawl a customer's website with Firecrawl and dump the markdown into a
# run-dir's scrape/ folder. Used by Stage 2 of /base-agent.
#
# Args:
#   --url <url>          (required) site to crawl
#   --out-dir <dir>      (required) directory to write outputs into
#   --max-pages <N>      (optional, default 50) crawl page cap
#   --help               print usage
#
# Outputs:
#   <out-dir>/pages/<safe-filename>.md     one file per crawled page
#   <out-dir>/combined.md                  flattened concatenation
#
# Firecrawl API endpoint version assumption:
#   This script uses the v2 async crawl endpoints (Firecrawl moved v1 → v2):
#     POST https://api.firecrawl.dev/v2/crawl       → returns {success, id, url}
#     GET  https://api.firecrawl.dev/v2/crawl/{id}  → polls; on completion
#                                                     returns {status:"completed", data:[...]}
#   If Firecrawl bumps versions again or changes the response shape, update
#   the two curl URLs below and the Python parser at the bottom.
#
# Conventions: ASCII markers [OK] / [ERR] / [INFO]; Python3 for JSON; never
# writes outside --out-dir.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: bash scripts/firecrawl-scrape.sh --url <url> --out-dir <dir> [--max-pages <N>]

Required:
  --url <url>         Site to crawl (e.g. https://example.com)
  --out-dir <dir>     Directory to write pages/ and combined.md into

Optional:
  --max-pages <N>     Crawl page cap (default 100)
  --help              Show this help and exit

Writes:
  <out-dir>/pages/<slug>.md   one file per page
  <out-dir>/combined.md       all pages joined with --- separators

Exits 1 on Firecrawl >=400 or polling timeout.
EOF
}

URL=""
OUT_DIR=""
# Default cap of 100 covers virtually every SMB site. Bumped from 50 after a
# Teleca onboarding where the original 50-page cap missed the /pricing tree
# and the brain-doc had to be rebuilt manually. The crawl naturally stops
# when all on-domain pages are reached — Firecrawl v2 defaults to
# allowExternalLinks:false, so it never wanders to news.com.au via a blog
# link. The cap only kicks in for sites that genuinely have >100 internal
# pages (rare for SMBs); it's there because Firecrawl bills per page.
MAX_PAGES=100

while [ $# -gt 0 ]; do
  case "$1" in
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --max-pages)
      MAX_PAGES="${2:-50}"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "[ERR] unknown arg: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$URL" ]; then
  echo "[ERR] --url is required" >&2
  exit 1
fi
if [ -z "$OUT_DIR" ]; then
  echo "[ERR] --out-dir is required" >&2
  exit 1
fi

# Source env (resolves FIRECRAWL_API_KEY etc.) — env-check.sh exits 1 on
# missing vars, so if it returns we know the key is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env-check.sh" >/dev/null

mkdir -p "$OUT_DIR/pages"

echo "[INFO] kicking off Firecrawl crawl for $URL (max-pages=$MAX_PAGES)"

# Build the kickoff payload. limit caps page count. (Firecrawl v2 dropped
# the respectRobots field — robots.txt is honoured by default; use
# ignoreRobotsTxt:true if you ever need to override.)
KICKOFF_PAYLOAD="$(python3 - "$URL" "$MAX_PAGES" <<'PY'
import json, sys
url, max_pages = sys.argv[1], int(sys.argv[2])
print(json.dumps({
    "url": url,
    "limit": max_pages,
    "scrapeOptions": {"formats": ["markdown"]},
}))
PY
)"

KICKOFF_RAW="$(mktemp)"
trap 'rm -f "$KICKOFF_RAW"' EXIT

HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$KICKOFF_RAW" -w "%{http_code}" \
  -X POST "https://api.firecrawl.dev/v2/crawl" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$KICKOFF_PAYLOAD")"

if [ "$HTTP_CODE" -ge 400 ]; then
  echo "[ERR] Firecrawl kickoff returned HTTP $HTTP_CODE" >&2
  cat "$KICKOFF_RAW" >&2
  echo >&2
  exit 1
fi

JOB_ID="$(python3 - "$KICKOFF_RAW" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
# v2 returns {"success": true, "id": "...", "url": "..."} on kickoff.
print(data.get("id") or data.get("jobId") or "")
PY
)"

if [ -z "$JOB_ID" ]; then
  echo "[ERR] Firecrawl kickoff response had no id" >&2
  cat "$KICKOFF_RAW" >&2
  echo >&2
  exit 1
fi

echo "[INFO] crawl job id=$JOB_ID — polling every 5s (timeout 5min)"

POLL_RAW="$(mktemp)"
trap 'rm -f "$KICKOFF_RAW" "$POLL_RAW"' EXIT

# 5min timeout = 60 polls @ 5s.
MAX_POLLS=60
POLL=0
STATUS=""
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  HTTP_CODE="$(curl --ssl-no-revoke -sS -o "$POLL_RAW" -w "%{http_code}" \
    -X GET "https://api.firecrawl.dev/v2/crawl/$JOB_ID" \
    -H "Authorization: Bearer $FIRECRAWL_API_KEY")"

  if [ "$HTTP_CODE" -ge 400 ]; then
    echo "[ERR] Firecrawl poll returned HTTP $HTTP_CODE" >&2
    cat "$POLL_RAW" >&2
    echo >&2
    exit 1
  fi

  STATUS="$(python3 - "$POLL_RAW" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("status", ""))
except Exception:
    print("")
PY
)"

  echo "[INFO] poll #$POLL: status=$STATUS"

  case "$STATUS" in
    completed)
      break
      ;;
    failed|cancelled)
      echo "[ERR] Firecrawl job ended with status=$STATUS" >&2
      cat "$POLL_RAW" >&2
      echo >&2
      exit 1
      ;;
  esac

  sleep 5
done

if [ "$STATUS" != "completed" ]; then
  echo "[ERR] Firecrawl crawl did not complete within 5min (last status=$STATUS)" >&2
  exit 1
fi

# Parse the completed payload, write per-page files and combined.md.
SUMMARY="$(python3 - "$POLL_RAW" "$OUT_DIR" <<'PY'
import json, os, re, sys

poll_path, out_dir = sys.argv[1], sys.argv[2]
pages_dir = os.path.join(out_dir, "pages")
os.makedirs(pages_dir, exist_ok=True)

with open(poll_path, "r", encoding="utf-8") as f:
    payload = json.load(f)

pages = payload.get("data") or []

def slugify_url(url: str, idx: int) -> str:
    # Strip protocol; replace non-safe chars with '-'; cap length.
    s = re.sub(r"^https?://", "", url or "")
    s = re.sub(r"[^a-zA-Z0-9._-]+", "-", s).strip("-")
    if not s:
        s = f"page-{idx:03d}"
    return s[:120] or f"page-{idx:03d}"

written = 0
total_chars = 0
combined_chunks = []
seen_names = set()
for i, p in enumerate(pages, 1):
    md = p.get("markdown") or ""
    if not md:
        # Some Firecrawl responses nest content under p["data"]; tolerate.
        nested = p.get("data") or {}
        md = nested.get("markdown") or ""
    if not md:
        continue
    meta = p.get("metadata") or {}
    page_url = meta.get("sourceURL") or meta.get("url") or p.get("url") or f"page-{i}"
    base = slugify_url(page_url, i)
    name = base
    n = 2
    # Avoid filename collisions when two URLs slug to the same string.
    while name in seen_names:
        name = f"{base}-{n}"
        n += 1
    seen_names.add(name)
    fname = f"{name}.md"
    with open(os.path.join(pages_dir, fname), "w", encoding="utf-8") as f:
        f.write(md)
    written += 1
    total_chars += len(md)
    header = f"<!-- source: {page_url} -->\n"
    combined_chunks.append(header + md)

combined_path = os.path.join(out_dir, "combined.md")
with open(combined_path, "w", encoding="utf-8") as f:
    f.write("\n\n---\n\n".join(combined_chunks))

print(f"{written}\t{total_chars}")
PY
)"

PAGES_WRITTEN="$(echo "$SUMMARY" | cut -f1)"
CHARS_TOTAL="$(echo "$SUMMARY" | cut -f2)"

# M23 Fix 4: zero-bytes is a hard halt. Previously the script wrote a 0-byte
# combined.md and exited 0; downstream stages then synthesized a brain-doc
# from nothing. Catch it here so the operator gets one clear actionable line
# instead of a cascade of weird failures three stages later.
if [ "$CHARS_TOTAL" -eq 0 ]; then
  echo "[ERR] firecrawl-scrape: 0 chars extracted from $URL. Site may be JS-only or unreachable. Confirm the URL renders content with a real browser, then re-run /base-agent." >&2
  exit 1
fi

echo "[OK] scraped $PAGES_WRITTEN pages, $CHARS_TOTAL chars total, written to $OUT_DIR"
exit 0
