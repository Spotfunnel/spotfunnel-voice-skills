-- migrations/operator_ui_deployment_log.sql
-- Audit log of every external mutation made by /base-agent during onboarding.
-- Read by /base-agent remove [slug] to replay inverse operations and tear
-- down a deployment cleanly. Append-only at write time, status-flipped
-- (active → reversed) at remove time. Survives customer/run row deletion
-- (text refs, no FK cascade) so the audit trail outlives the deployment.
-- Applied to Supabase project ldpvfolmloexlmeoqkxo (voicemachine) on 2026-04-28.

create table if not exists operator_ui.deployment_log (
  id              uuid primary key default gen_random_uuid(),
  customer_slug   text not null,
  run_id_text     text,
  stage           int not null,
  system          text not null,
  action          text not null,
  target_kind     text not null,
  target_id       text not null,
  payload         jsonb,
  inverse_op      text not null,
  inverse_payload jsonb,
  status          text not null default 'active'
                  check (status in ('active', 'reversed', 'reverse_failed', 'reverse_skipped')),
  reversed_at     timestamptz,
  reverse_error   text,
  created_at      timestamptz not null default now()
);

create index if not exists deployment_log_slug_status_idx
  on operator_ui.deployment_log (customer_slug, status, created_at desc);

create index if not exists deployment_log_run_id_idx
  on operator_ui.deployment_log (run_id_text)
  where run_id_text is not null;

-- RLS off — service-role-only table, accessed by base-agent skill scripts
-- and the operator UI's hidden internal admin path (no public-facing read).
alter table operator_ui.deployment_log enable row level security;
create policy "service role full access" on operator_ui.deployment_log
  for all using (true) with check (true);
