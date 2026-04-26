#!/usr/bin/env bash
# scripts/supabase.sh
#
# Lightweight curl wrappers around Supabase REST for the operator_ui schema.
# Sourced by state.sh and (in M9) the stage scripts. Only required when
# USE_SUPABASE_BACKEND=1 — the legacy file-based path doesn't need this file.
#
# Required env:
#   SUPABASE_OPERATOR_URL                e.g. https://ldpvfolmloexlmeoqkxo.supabase.co
#   SUPABASE_OPERATOR_SERVICE_ROLE_KEY   service-role key (full bypass; server-side only)
#
# All requests target the operator_ui schema via Accept-Profile / Content-Profile
# headers — Supabase REST exposes non-public schemas this way.

set -euo pipefail

SUPABASE_OPERATOR_URL="${SUPABASE_OPERATOR_URL:?must set SUPABASE_OPERATOR_URL}"
SUPABASE_OPERATOR_SERVICE_ROLE_KEY="${SUPABASE_OPERATOR_SERVICE_ROLE_KEY:?must set SUPABASE_OPERATOR_SERVICE_ROLE_KEY}"
SUPABASE_OPERATOR_SCHEMA="operator_ui"

# POST /rest/v1/<table> with body as JSON. Returns inserted row(s) on stdout.
supabase_post() {
  local table="$1"
  local body="$2"
  curl --ssl-no-revoke -sS -X POST \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$body" \
    "$SUPABASE_OPERATOR_URL/rest/v1/$table"
}

# GET /rest/v1/<query>  (caller provides query path including ?filter=eq.foo&select=...)
supabase_get() {
  local query="$1"
  curl --ssl-no-revoke -sS \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    "$SUPABASE_OPERATOR_URL/rest/v1/$query"
}

# PATCH /rest/v1/<query> with body as JSON. Returns updated row(s).
supabase_patch() {
  local query="$1"
  local body="$2"
  curl --ssl-no-revoke -sS -X PATCH \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$body" \
    "$SUPABASE_OPERATOR_URL/rest/v1/$query"
}

# DELETE /rest/v1/<query>. Returns deleted row(s) when Prefer: return=representation.
# Used by tests for cleanup; stage scripts should not delete rows in normal flow.
supabase_delete() {
  local query="$1"
  curl --ssl-no-revoke -sS -X DELETE \
    -H "apikey: $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_OPERATOR_SERVICE_ROLE_KEY" \
    -H "Accept-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Content-Profile: $SUPABASE_OPERATOR_SCHEMA" \
    -H "Prefer: return=representation" \
    "$SUPABASE_OPERATOR_URL/rest/v1/$query"
}
