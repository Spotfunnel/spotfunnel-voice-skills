-- migrations/operator_ui_spawn_run.sql
-- M23 Fix 5 — atomic refine spawn-run.
--
-- The pre-M23 helper (scripts/refine-spawn-run.sh) did two separate POSTs:
--   1. INSERT INTO runs (..., refined_from_run_id, ...)
--   2. INSERT INTO artifacts (run_id, artifact_name, content, size_bytes) ...
-- If the script process died between (1) and (2), the new run existed with
-- zero artifacts. The next refine retry would re-spawn ANOTHER empty run on
-- top, never noticing the first one was malformed.
--
-- Fix: a Postgres function that does both inserts in a single transaction.
-- PostgREST's /rpc/<fn> exposes it; the helper script becomes a thin wrapper.
-- Apply this on top of operator_ui_schema.sql. Idempotent (CREATE OR REPLACE).

create or replace function operator_ui.spawn_refine_run(
  source_run_id uuid
)
returns table (
  slug_with_ts text,
  id uuid
)
language plpgsql
security definer
set search_path = operator_ui, public
as $$
declare
  src record;
  ts_part text;
  new_slug_with_ts text;
  new_state jsonb;
  new_run_id uuid;
begin
  -- 1. Read the source run + its customer slug. Single SELECT joining
  --    runs → customers — both inserts that follow share this snapshot.
  select r.id,
         r.customer_id,
         r.slug_with_ts as src_slug_with_ts,
         coalesce(r.state, '{}'::jsonb) as state,
         c.slug as customer_slug
    into src
    from operator_ui.runs r
    join operator_ui.customers c on c.id = r.customer_id
   where r.id = source_run_id;

  if not found then
    raise exception 'spawn_refine_run: source run % not found', source_run_id;
  end if;

  -- 2. Build the new slug_with_ts. Format mirrors the prior shell helper:
  --    "<customer-slug>-refine-YYYY-MM-DDTHH-MM-SSZ" (UTC, no colons).
  ts_part := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24-MI-SS') || 'Z';
  new_slug_with_ts := src.customer_slug || '-refine-' || ts_part;

  -- 3. Compose the new state with provenance noted (matches prior helper).
  new_state := src.state || jsonb_build_object(
    'refined_from_slug_with_ts', src.src_slug_with_ts
  );

  -- 4. INSERT the new run row + COPY artifacts forward — atomic by virtue of
  --    being one function = one transaction. Either both succeed or neither
  --    persists. The duplicate-key guard on slug_with_ts prevents a re-tried
  --    second-of-millisecond run from clobbering the first.
  insert into operator_ui.runs (
    customer_id, slug_with_ts, started_at, state, refined_from_run_id
  )
  values (
    src.customer_id,
    new_slug_with_ts,
    now(),
    new_state,
    source_run_id
  )
  returning operator_ui.runs.id into new_run_id;

  insert into operator_ui.artifacts (run_id, artifact_name, content, size_bytes)
  select new_run_id, a.artifact_name, a.content, a.size_bytes
    from operator_ui.artifacts a
   where a.run_id = source_run_id;

  -- 5. Return the new (slug_with_ts, id) tuple. PostgREST surfaces this as
  --    the JSON body of POST /rpc/spawn_refine_run.
  slug_with_ts := new_slug_with_ts;
  id := new_run_id;
  return next;
  return;
end
$$;

-- Tighten privileges. service_role keeps EXECUTE (the skill calls it via
-- SUPABASE_OPERATOR_SERVICE_ROLE_KEY); anon/authenticated have no business
-- spawning runs.
revoke all on function operator_ui.spawn_refine_run(uuid) from public;
grant execute on function operator_ui.spawn_refine_run(uuid) to service_role;

-- Reload PostgREST so the new RPC is discoverable on the REST surface.
notify pgrst, 'reload schema';
