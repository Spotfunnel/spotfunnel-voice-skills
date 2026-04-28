-- migrations/operator_ui_agent_tools.sql
-- Per-customer base-tools configuration. Written at Stage 6.5 of /base-agent
-- when transfer + take-message tools get attached to a freshly-created agent.
-- Read at runtime by the dashboard-server's /webhooks/take-message handler
-- to look up the recipient channel + address for an inbound message.
-- Cleaned up by /base-agent remove when a customer is torn down.
-- Applied to Supabase project ldpvfolmloexlmeoqkxo (voicemachine) on 2026-04-28.

create table if not exists operator_ui.agent_tools (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null references operator_ui.customers(id) on delete cascade,
  tool_name              text not null
                         check (tool_name in ('transfer', 'take_message')),
  config                 jsonb not null,
  ultravox_tool_id       text,
  attached_to_agent_id   text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (customer_id, tool_name)
);

create index if not exists agent_tools_customer_idx
  on operator_ui.agent_tools (customer_id);

create index if not exists agent_tools_attached_agent_idx
  on operator_ui.agent_tools (attached_to_agent_id)
  where attached_to_agent_id is not null;

-- updated_at auto-bump trigger so edits via UI / scripts always reflect last-write time.
create or replace function operator_ui.bump_agent_tools_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists agent_tools_updated_at_trigger on operator_ui.agent_tools;
create trigger agent_tools_updated_at_trigger
before update on operator_ui.agent_tools
for each row execute function operator_ui.bump_agent_tools_updated_at();

alter table operator_ui.agent_tools enable row level security;
create policy "service role full access" on operator_ui.agent_tools
  for all using (true) with check (true);
