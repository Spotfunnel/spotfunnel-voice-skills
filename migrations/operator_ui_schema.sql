-- migrations/operator_ui_schema.sql
-- Operator UI schema. Read at every /base-agent run + refine.
-- Applied to Supabase project ldpvfolmloexlmeoqkxo (voicemachine) on 2026-04-26.

create schema if not exists operator_ui;

create table operator_ui.customers (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  created_at timestamptz not null default now()
);

create table operator_ui.runs (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references operator_ui.customers(id) on delete cascade,
  slug_with_ts text unique not null,
  started_at timestamptz not null,
  state jsonb not null,
  stage_complete int not null default 0,
  refined_from_run_id uuid references operator_ui.runs(id),
  created_at timestamptz not null default now()
);

create table operator_ui.artifacts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  artifact_name text not null,
  content text not null,
  size_bytes int not null,
  created_at timestamptz not null default now(),
  unique (run_id, artifact_name)
);

create table operator_ui.annotations (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  artifact_name text not null,
  quote text not null,
  prefix text not null,
  suffix text not null,
  char_start int not null,
  char_end int not null,
  comment text not null,
  status text not null default 'open',
  author_name text not null,
  created_at timestamptz not null default now(),
  resolved_by_run_id uuid references operator_ui.runs(id),
  resolved_classification text
);

create table operator_ui.feedback (
  id text primary key,
  customer_id uuid not null references operator_ui.customers(id),
  run_id uuid not null references operator_ui.runs(id),
  source_annotation_id uuid not null references operator_ui.annotations(id),
  artifact_name text not null,
  quote text not null,
  comment text not null,
  status text not null default 'open',
  elevated_to_lesson_id text,
  created_at timestamptz not null default now()
);

create table operator_ui.lessons (
  id text primary key,
  title text not null,
  pattern text not null,
  fix text not null,
  observed_in_customer_ids uuid[] not null,
  source_feedback_ids text[] not null,
  promoted_to_prompt boolean not null default false,
  promoted_at timestamptz,
  promoted_to_file text,
  created_at timestamptz not null default now()
);

create table operator_ui.verifications (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  verified_at timestamptz not null,
  summary jsonb not null,
  checks jsonb not null,
  created_at timestamptz not null default now()
);

-- RLS: permissive within schema; access gated by Vercel password (humans) and service-role key (skill).
alter table operator_ui.customers enable row level security;
alter table operator_ui.runs enable row level security;
alter table operator_ui.artifacts enable row level security;
alter table operator_ui.annotations enable row level security;
alter table operator_ui.feedback enable row level security;
alter table operator_ui.lessons enable row level security;
alter table operator_ui.verifications enable row level security;

create policy "all_access" on operator_ui.customers for all using (true);
create policy "all_access" on operator_ui.runs for all using (true);
create policy "all_access" on operator_ui.artifacts for all using (true);
create policy "all_access" on operator_ui.annotations for all using (true);
create policy "all_access" on operator_ui.feedback for all using (true);
create policy "all_access" on operator_ui.lessons for all using (true);
create policy "all_access" on operator_ui.verifications for all using (true);

-- indexes
create index runs_customer_started_idx on operator_ui.runs(customer_id, started_at desc);
create index artifacts_run_name_idx on operator_ui.artifacts(run_id, artifact_name);
create index annotations_run_status_idx on operator_ui.annotations(run_id, status);
create index feedback_status_created_idx on operator_ui.feedback(status, created_at);
create index lessons_promoted_created_idx on operator_ui.lessons(promoted_to_prompt, created_at);
