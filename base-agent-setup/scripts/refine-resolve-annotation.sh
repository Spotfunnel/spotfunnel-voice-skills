#!/usr/bin/env bash
# scripts/refine-resolve-annotation.sh <annotation_id> <new_run_id> <classification>
#
# Mark an annotation resolved with the new run's id and the classification
# the orchestrator chose ('per-run' | 'feedback'). The "mixed" branch in
# the orchestrator's flow collapses to 'feedback' here — the feedback row
# (with source_annotation_id) is the durable record of the behavior half;
# the per-run half is applied silently in the regenerated artifact.
#
# Stdout: nothing on success.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/supabase.sh"

AID="${1:-}"
NEW_RUN_ID="${2:-}"
CLASS="${3:-}"

if [ -z "$AID" ] || [ -z "$NEW_RUN_ID" ] || [ -z "$CLASS" ]; then
  echo "Usage: refine-resolve-annotation.sh <annotation_id> <new_run_id> <classification>" >&2
  exit 1
fi
case "$CLASS" in
  per-run|feedback) ;;
  *)
    echo "refine-resolve-annotation: classification must be per-run|feedback (got '$CLASS')" >&2
    exit 1
    ;;
esac

BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "status": "resolved",
    "resolved_by_run_id": sys.argv[1],
    "resolved_classification": sys.argv[2],
}))
' "$NEW_RUN_ID" "$CLASS")"

RESP="$(supabase_patch "annotations?id=eq.${AID}" "$BODY")"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not isinstance(d, list) or not d:
    sys.stderr.write(f"refine-resolve-annotation: patch returned no row for {sys.argv[2]}: {sys.argv[1]}\n")
    sys.exit(1)
' "$RESP" "$AID"
