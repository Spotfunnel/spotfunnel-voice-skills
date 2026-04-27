-- migrations/operator_ui_auth.sql
-- M22 — Supabase Auth (magic-link) + two-email allowlist + per-user attribution.
-- Apply ON TOP OF migrations/operator_ui_schema.sql. Idempotent.
--
-- What this does:
--  1. Adds operator_ui.annotations.author_email (defaulted from JWT email).
--  2. Replaces the permissive "all_access" RLS policies with allowlist-gated
--     auth.jwt()->>email policies on every operator_ui.* table.
--  3. Locks anon down to NO read / NO write on operator_ui.* (everything goes
--     through Supabase Auth or service-role).
--  4. Forces annotation insert to attribute itself to the actual JWT email
--     (cannot impersonate).
--  5. Reloads PostgREST.
--
-- service_role retains full bypass — the local /base-agent skill still uses
-- SUPABASE_OPERATOR_SERVICE_ROLE_KEY and is unaffected.

-- ============================================================================
-- 1. annotations.author_email
-- ============================================================================

alter table operator_ui.annotations
  add column if not exists author_email text
  default (auth.jwt() ->> 'email');

-- author_name was NOT NULL pre-M22; make it nullable so future rows can omit
-- it entirely (the JWT email is the source of truth now). Existing rows keep
-- whatever localStorage-era string they had.
alter table operator_ui.annotations
  alter column author_name drop not null;

create index if not exists annotations_run_email_idx
  on operator_ui.annotations(run_id, author_email);

-- ============================================================================
-- 2. RLS — drop permissive policies, add allowlist policies
-- ============================================================================

-- Helper note: every policy below gates on the same allowlist. If the list
-- grows, edit these 7 tables here; do NOT scatter the membership check.

-- customers (read-only from UI)
drop policy if exists "all_access" on operator_ui.customers;
drop policy if exists "auth_allowlist_read" on operator_ui.customers;
create policy "auth_allowlist_read" on operator_ui.customers
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- runs (read-only from UI)
drop policy if exists "all_access" on operator_ui.runs;
drop policy if exists "auth_allowlist_read" on operator_ui.runs;
create policy "auth_allowlist_read" on operator_ui.runs
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- artifacts (read-only from UI)
drop policy if exists "all_access" on operator_ui.artifacts;
drop policy if exists "auth_allowlist_read" on operator_ui.artifacts;
create policy "auth_allowlist_read" on operator_ui.artifacts
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- verifications (read-only from UI)
drop policy if exists "all_access" on operator_ui.verifications;
drop policy if exists "auth_allowlist_read" on operator_ui.verifications;
create policy "auth_allowlist_read" on operator_ui.verifications
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- lessons (read-only from UI)
drop policy if exists "all_access" on operator_ui.lessons;
drop policy if exists "auth_allowlist_read" on operator_ui.lessons;
create policy "auth_allowlist_read" on operator_ui.lessons
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- annotations: read + update + delete via allowlist; insert has its own policy
-- enforcing self-attribution (see #4 below).
drop policy if exists "all_access" on operator_ui.annotations;
drop policy if exists "auth_allowlist_read" on operator_ui.annotations;
drop policy if exists "auth_allowlist_update" on operator_ui.annotations;
drop policy if exists "auth_allowlist_delete" on operator_ui.annotations;
create policy "auth_allowlist_read" on operator_ui.annotations
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));
create policy "auth_allowlist_update" on operator_ui.annotations
  for update to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'))
  with check ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));
create policy "auth_allowlist_delete" on operator_ui.annotations
  for delete to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- feedback: read + write via allowlist (no per-user attribution column on this
-- table — feedback rows are derived from annotations, attribution flows through
-- the source_annotation_id FK).
drop policy if exists "all_access" on operator_ui.feedback;
drop policy if exists "auth_allowlist_read" on operator_ui.feedback;
drop policy if exists "auth_allowlist_write" on operator_ui.feedback;
create policy "auth_allowlist_read" on operator_ui.feedback
  for select to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));
create policy "auth_allowlist_write" on operator_ui.feedback
  for all to authenticated
  using ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'))
  with check ((auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com'));

-- ============================================================================
-- 3. Revoke anon access entirely
-- ============================================================================
--
-- Pre-M22 design: anon SELECT everywhere + INSERT/UPDATE/DELETE on annotations
-- + feedback, gated only by Vercel password. Post-M22: every UI render goes
-- through middleware that requires a Supabase session, so anon never needs to
-- talk to operator_ui.* at all. Revoke wholesale; service_role still bypasses
-- for the local skill.

revoke select on all tables in schema operator_ui from anon;
revoke insert, update, delete on operator_ui.annotations from anon;
revoke insert, update, delete on operator_ui.feedback from anon;
revoke usage, select on all sequences in schema operator_ui from anon;

-- Default privileges for future tables: anon gets nothing. authenticated gets
-- SELECT only by default (write grants stay explicit per-table).
alter default privileges in schema operator_ui revoke select on tables from anon;
alter default privileges in schema operator_ui revoke usage, select on sequences from anon;

-- authenticated needs explicit table-level grants. PostgREST + RLS together
-- means: grant the SQL privilege, then the policy decides which rows.
grant select on all tables in schema operator_ui to authenticated;
grant insert, update, delete on operator_ui.annotations to authenticated;
grant insert, update, delete on operator_ui.feedback to authenticated;
grant usage, select on all sequences in schema operator_ui to authenticated;
alter default privileges in schema operator_ui grant select on tables to authenticated;
alter default privileges in schema operator_ui grant usage, select on sequences to authenticated;

-- ============================================================================
-- 4. Self-attribution: insert must claim only your own email
-- ============================================================================

drop policy if exists "auth_self_attribution" on operator_ui.annotations;
create policy "auth_self_attribution" on operator_ui.annotations
  for insert to authenticated
  with check (
    (auth.jwt() ->> 'email') in ('kye@getspotfunnel.com', 'leo@getspotfunnel.com')
    and author_email = (auth.jwt() ->> 'email')
  );

-- ============================================================================
-- 5. Reload PostgREST
-- ============================================================================
notify pgrst, 'reload schema';
