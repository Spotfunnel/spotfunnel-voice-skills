#!/usr/bin/env bash
# scripts/review-list-clusters.sh
#
# Cross-customer feedback clusters (size >= 2). Emits JSONL on stdout —
# same schema as refine-cluster-feedback.sh --all-customers, which this
# delegates to. Used by /base-agent review-feedback phase 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/refine-cluster-feedback.sh" --all-customers
