-- Run this against a fresh Supabase project to bootstrap the dashboard backend.
-- Generated 2026-04-25 from spotfunnel's production dashboard schema.
--
-- ASSUMPTIONS / NOTES
--   * `auth.users` is managed by Supabase Auth — already exists in any Supabase project.
--     `public.users.id` FKs into it (ON DELETE CASCADE).
--   * RLS helper functions `auth.uid()` / `auth.role()` are stock Supabase — no setup required.
--   * Custom helper SQL functions used by RLS policies (`get_user_role`, `get_user_workspace_id`)
--     are defined below in section 5 BEFORE the policies in section 6 reference them.
--   * Apply order: extensions → tables → indexes → functions → triggers → RLS enable + policies.
--   * No data is included. Schema only.
--   * Realtime publication memberships, storage buckets, and edge function deploys are NOT in
--     this file — those are separate concerns (Supabase dashboard / dashboard-server repo).
--
-- =====================================================================
-- 1. EXTENSIONS
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- legacy uuid helpers (kept for parity with prod)


-- =====================================================================
-- 2. TABLES (created in FK-dependency order)
-- =====================================================================

-- ---------- workspaces (root tenant table) ----------
CREATE TABLE IF NOT EXISTS public.workspaces (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                       text NOT NULL,
  slug                       text NOT NULL UNIQUE,
  ultravox_agent_ids         text[] NOT NULL DEFAULT '{}'::text[],
  telnyx_numbers             text[] DEFAULT '{}'::text[],
  timezone                   text DEFAULT 'Australia/Brisbane'::text,
  plan                       text DEFAULT 'inbound'::text
                               CHECK (plan = ANY (ARRAY['inbound'::text, 'inbound + outbound'::text, 'outbound'::text])),
  config                     jsonb NOT NULL DEFAULT '{"outcomes": [{"key": "converted", "color": "#0B6D3E", "label": "Converted", "is_success": true, "description": "Primary success action completed"}, {"key": "info", "color": "#555555", "label": "Info only", "description": "Question answered, no action taken"}, {"key": "message", "color": "#2563eb", "label": "Message taken", "description": "Caller left a message"}, {"key": "transferred", "color": "#B85C93", "label": "Transferred", "description": "Call transferred to human"}], "stat_cards": [{"key": "total_calls", "type": "universal", "label": "Calls today"}, {"key": "converted", "type": "outcome", "label": "Converted"}, {"key": "answer_rate", "type": "universal", "label": "Answer rate"}, {"key": "avg_duration", "type": "universal", "label": "Avg duration"}]}'::jsonb,
  created_at                 timestamptz DEFAULT now(),
  judging_enabled            boolean NOT NULL DEFAULT false,
  max_judged_calls_per_day   integer NOT NULL DEFAULT 0
);
COMMENT ON COLUMN public.workspaces.plan IS 'Product tier. ''inbound'' = AI receptionist only. ''outbound'' = outbound campaigns only. ''inbound + outbound'' = both. Admin-only field.';
COMMENT ON COLUMN public.workspaces.config IS 'Workspace config JSONB: outcomes, stat_cards, agent_names, internal_numbers, judging, auto_resolved_outcomes. See docs/plans/2026-04-17-self-improving-judging-design.md';
COMMENT ON COLUMN public.workspaces.judging_enabled IS 'Master toggle for the self-improving judging system. Default OFF; superadmin flips per workspace.';
COMMENT ON COLUMN public.workspaces.max_judged_calls_per_day IS 'Daily cap on per-call judging (cost guardrail). 0 = no calls judged even if enabled.';


-- ---------- users (FKs auth.users + workspaces) ----------
CREATE TABLE IF NOT EXISTS public.users (
  id            uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  workspace_id  uuid REFERENCES public.workspaces(id),
  email         text NOT NULL UNIQUE,
  name          text,
  role          text DEFAULT 'viewer'::text
                  CHECK (role = ANY (ARRAY['viewer'::text, 'admin'::text, 'owner'::text, 'superadmin'::text])),
  created_at    timestamptz DEFAULT now()
);


-- ---------- calls (FKs workspaces + users) ----------
CREATE TABLE IF NOT EXISTS public.calls (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ultravox_call_id    text UNIQUE,
  workspace_id        uuid NOT NULL REFERENCES public.workspaces(id),
  agent_id            text,
  agent_name          text,
  caller_phone        text,
  caller_name         text,
  business_name       text,
  category            text,
  outcome             text,
  summary             text,
  short_summary       text,
  interest            text,
  follow_up_needed    boolean DEFAULT false,
  follow_up_details   text,
  transfer_attempted  boolean DEFAULT false,
  transfer_target     text,
  message_for_team    text,
  duration_sec        integer,
  recording_url       text,
  transcript          jsonb,
  direction           text DEFAULT 'inbound'::text
                        CHECK (direction = ANY (ARRAY['inbound'::text, 'outbound'::text])),
  campaign_id         uuid,
  contact_id          uuid,
  started_at          timestamptz,
  ended_at            timestamptz,
  created_at          timestamptz DEFAULT now(),
  is_test             boolean NOT NULL DEFAULT false,
  status              text NOT NULL DEFAULT 'open'::text
                        CHECK (status = ANY (ARRAY['open'::text, 'resolved'::text])),
  resolved_at         timestamptz,
  resolved_by         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  intent              text
);
COMMENT ON COLUMN public.calls.is_test IS 'True if the call originated from the Ultravox web UI, API (serverWebSocket medium), or a SpotFunnel-owned test phone number. Excluded from customer-facing dashboard queries.';
COMMENT ON COLUMN public.calls.status IS 'Open = needs attention; resolved = team has actioned it. Shared across the workspace team (not per-user).';


-- ---------- workflow_errors ----------
CREATE TABLE IF NOT EXISTS public.workflow_errors (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid REFERENCES public.workspaces(id),
  source        text NOT NULL,
  severity      text DEFAULT 'warning'::text
                  CHECK (severity = ANY (ARRAY['info'::text, 'warning'::text, 'error'::text])),
  message       text NOT NULL,
  payload       jsonb,
  resolved      boolean DEFAULT false,
  created_at    timestamptz DEFAULT now(),
  resolved_at   timestamptz
);


-- ---------- feedback ----------
CREATE TABLE IF NOT EXISTS public.feedback (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id               uuid NOT NULL REFERENCES public.calls(id),
  workspace_id          uuid NOT NULL REFERENCES public.workspaces(id),
  user_id               uuid REFERENCES public.users(id) ON DELETE SET NULL,
  message               text NOT NULL,
  status                text DEFAULT 'open'::text
                          CHECK (status = ANY (ARRAY['open'::text, 'resolved'::text])),
  resolved_at           timestamptz,
  resolved_by           uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at            timestamptz DEFAULT now(),
  notification_sent_at  timestamptz
);


-- ---------- call_saves (per-user bookmarks + share tokens) ----------
CREATE TABLE IF NOT EXISTS public.call_saves (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id       uuid NOT NULL REFERENCES public.calls(id) ON DELETE CASCADE,
  workspace_id  uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  share_token   text NOT NULL UNIQUE,
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT (now() + '90 days'::interval),
  revoked_at    timestamptz
);
COMMENT ON TABLE public.call_saves IS 'Per-user favourites/bookmarks on calls. Each save carries a random share_token for public link sharing (used on referral-worthy calls).';
COMMENT ON COLUMN public.call_saves.share_token IS 'Random unguessable token. Public /share/[token] route serves the transcript + summary + recording without auth.';


-- ---------- call_judgements (self-improving judging system) ----------
CREATE TABLE IF NOT EXISTS public.call_judgements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id         uuid NOT NULL REFERENCES public.calls(id) ON DELETE CASCADE,
  workspace_id    uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  agent_id        text NOT NULL,
  rule_id         text NOT NULL,
  rule_type       text NOT NULL
                    CHECK (rule_type = ANY (ARRAY['deterministic'::text, 'llm_simple'::text, 'llm_nuanced'::text, 'signal'::text])),
  result          text NOT NULL
                    CHECK (result = ANY (ARRAY['pass'::text, 'warning'::text, 'violation'::text, 'not_tested'::text, 'signal_fired'::text])),
  severity        text CHECK (severity = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])),
  score           numeric,
  cue             text,
  justification   text,
  details         jsonb,
  judge_model     text,
  grader_version  text NOT NULL,
  judged_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.call_judgements IS 'Per-call, per-rule judgement results. Superadmin-only read; service role writes via dashboard-server worker.';


-- ---------- judgement_clusters (self-references; daily-regenerated) ----------
CREATE TABLE IF NOT EXISTS public.judgement_clusters (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id                uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  agent_id                    text NOT NULL,
  rule_id                     text NOT NULL,
  period_start                timestamptz NOT NULL,
  period_end                  timestamptz NOT NULL,
  violation_count             integer NOT NULL,
  total_calls_judged          integer NOT NULL,
  frequency_pct               numeric GENERATED ALWAYS AS
                                (round(((100.0 * (violation_count)::numeric) / (NULLIF(total_calls_judged, 0))::numeric), 1)) STORED,
  severity                    text NOT NULL
                                CHECK (severity = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])),
  pattern_analysis_md         text NOT NULL,
  sample_call_ids             uuid[] NOT NULL DEFAULT '{}'::uuid[],
  status                      text NOT NULL DEFAULT 'open'::text
                                CHECK (status = ANY (ARRAY['open'::text, 'archived'::text, 'dismissed'::text, 'measuring'::text])),
  regressed_from_cluster_id   uuid REFERENCES public.judgement_clusters(id),
  archived_at                 timestamptz,
  archived_by                 uuid REFERENCES public.users(id) ON DELETE SET NULL,
  dismissed_until             timestamptz,
  generated_at                timestamptz NOT NULL DEFAULT now(),
  rank_score                  numeric,
  dismissed_at                timestamptz,
  dismissed_by                uuid
);
COMMENT ON TABLE public.judgement_clusters IS 'Daily-regenerated clusters of recurring violations per agent per rule. Ranked on /admin/health.';


-- ---------- judgement_fixes (audit log of fixes deployed) ----------
CREATE TABLE IF NOT EXISTS public.judgement_fixes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  agent_id      text NOT NULL,
  rule_id       text NOT NULL,
  cluster_id    uuid REFERENCES public.judgement_clusters(id) ON DELETE SET NULL,
  description   text NOT NULL,
  change_type   text CHECK (change_type = ANY (ARRAY['prompt'::text, 'kb'::text, 'tool'::text, 'voice'::text, 'other'::text])),
  deployed_at   timestamptz NOT NULL DEFAULT now(),
  deployed_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
  reverted_at   timestamptz,
  notes         text
);
COMMENT ON TABLE public.judgement_fixes IS 'Audit log of prompt/KB/tool changes deployed to fix violation clusters. Anchors the effective-window for future cluster generation.';


-- ---------- workspace_judging_usage (daily cap counters) ----------
CREATE TABLE IF NOT EXISTS public.workspace_judging_usage (
  workspace_id  uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  day           date NOT NULL,
  count         integer NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, day)
);


-- ---------- weekly_batch_runs ----------
CREATE TABLE IF NOT EXISTS public.weekly_batch_runs (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id            uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  week_start              date NOT NULL,
  week_end                date NOT NULL,
  status                  text NOT NULL DEFAULT 'pending'::text
                            CHECK (status = ANY (ARRAY['pending'::text, 'submitted'::text, 'in_progress'::text, 'completed'::text, 'partial'::text, 'failed'::text])),
  call_count              integer NOT NULL DEFAULT 0,
  openai_batch_ids        jsonb NOT NULL DEFAULT '[]'::jsonb,
  input_tokens_mini       integer NOT NULL DEFAULT 0,
  output_tokens_mini      integer NOT NULL DEFAULT 0,
  input_tokens_nuanced    integer NOT NULL DEFAULT 0,
  output_tokens_nuanced   integer NOT NULL DEFAULT 0,
  estimated_cost_usd      numeric NOT NULL DEFAULT 0,
  error                   text,
  submitted_at            timestamptz,
  completed_at            timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, week_start)
);
COMMENT ON COLUMN public.weekly_batch_runs.status IS 'pending=row created but submit not started; submitted=all batches handed to OpenAI; in_progress=at least one batch still processing; completed=all batches succeeded and results persisted; partial=some batches succeeded (results persisted) and some failed; failed=no batches succeeded';


-- ---------- reclassify_jobs (RLS DISABLED in prod — service role only) ----------
CREATE TABLE IF NOT EXISTS public.reclassify_jobs (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id           uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  status                 text NOT NULL DEFAULT 'pending'::text
                           CHECK (status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'failed'::text])),
  total                  integer NOT NULL DEFAULT 0,
  processed              integer NOT NULL DEFAULT 0,
  failed_count           integer NOT NULL DEFAULT 0,
  changed_outcome_keys   text[] NOT NULL DEFAULT '{}'::text[],
  changed_intent_keys    text[] NOT NULL DEFAULT '{}'::text[],
  triggered_by           uuid REFERENCES public.users(id) ON DELETE SET NULL,
  started_at             timestamptz,
  finished_at            timestamptz,
  error_message          text,
  created_at             timestamptz NOT NULL DEFAULT now()
);


-- =====================================================================
-- 3. INDEXES (non-PK / non-unique-on-column-already-declared)
-- =====================================================================

-- calls
CREATE INDEX IF NOT EXISTS calls_ultravox_id            ON public.calls (ultravox_call_id);
CREATE INDEX IF NOT EXISTS calls_workspace_ended        ON public.calls (workspace_id, ended_at DESC);
CREATE INDEX IF NOT EXISTS calls_workspace_outcome      ON public.calls (workspace_id, outcome);
CREATE INDEX IF NOT EXISTS calls_workspace_status_idx   ON public.calls (workspace_id, status, ended_at DESC);
CREATE INDEX IF NOT EXISTS calls_workspace_is_test_idx  ON public.calls (workspace_id, is_test, ended_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_intent             ON public.calls (workspace_id, intent) WHERE (intent IS NOT NULL);

-- feedback
CREATE INDEX IF NOT EXISTS feedback_workspace_status    ON public.feedback (workspace_id, status, created_at DESC);

-- call_saves
CREATE UNIQUE INDEX IF NOT EXISTS call_saves_call_user_uniq         ON public.call_saves (call_id, user_id);
CREATE INDEX IF NOT EXISTS call_saves_share_token_idx               ON public.call_saves (share_token);
CREATE INDEX IF NOT EXISTS call_saves_workspace_idx                 ON public.call_saves (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_call_saves_expires_at                ON public.call_saves (expires_at);
CREATE INDEX IF NOT EXISTS idx_call_saves_revoked_at                ON public.call_saves (revoked_at) WHERE (revoked_at IS NULL);
CREATE INDEX IF NOT EXISTS idx_call_saves_share_token_active        ON public.call_saves (share_token) WHERE (share_token IS NOT NULL);

-- call_judgements
CREATE INDEX IF NOT EXISTS call_judgements_agent_idx                ON public.call_judgements (agent_id, judged_at DESC);
CREATE INDEX IF NOT EXISTS call_judgements_call_idx                 ON public.call_judgements (call_id);
CREATE UNIQUE INDEX IF NOT EXISTS call_judgements_call_rule_version_uniq
                                                                    ON public.call_judgements (call_id, rule_id, grader_version);
CREATE INDEX IF NOT EXISTS call_judgements_workspace_rule_idx       ON public.call_judgements (workspace_id, rule_id, result, judged_at DESC);

-- judgement_clusters
CREATE INDEX IF NOT EXISTS judgement_clusters_agent_idx             ON public.judgement_clusters (workspace_id, agent_id, status, generated_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS judgement_clusters_open_uniq      ON public.judgement_clusters (workspace_id, agent_id, rule_id) WHERE (status = 'open'::text);
CREATE INDEX IF NOT EXISTS judgement_clusters_rule_idx              ON public.judgement_clusters (workspace_id, agent_id, rule_id, status);
CREATE INDEX IF NOT EXISTS judgement_clusters_workspace_status_idx  ON public.judgement_clusters (workspace_id, status, rank_score DESC NULLS LAST, generated_at DESC);

-- judgement_fixes
CREATE INDEX IF NOT EXISTS judgement_fixes_agent_rule_deployed_idx  ON public.judgement_fixes (agent_id, rule_id, deployed_at DESC);
CREATE INDEX IF NOT EXISTS judgement_fixes_agent_rule_idx           ON public.judgement_fixes (agent_id, rule_id, deployed_at DESC);
CREATE INDEX IF NOT EXISTS judgement_fixes_workspace_idx            ON public.judgement_fixes (workspace_id, deployed_at DESC);

-- weekly_batch_runs
CREATE INDEX IF NOT EXISTS weekly_batch_runs_status_idx             ON public.weekly_batch_runs (status, submitted_at DESC);
CREATE INDEX IF NOT EXISTS weekly_batch_runs_workspace_idx          ON public.weekly_batch_runs (workspace_id, week_start DESC);

-- reclassify_jobs
CREATE INDEX IF NOT EXISTS idx_reclassify_jobs_workspace_status     ON public.reclassify_jobs (workspace_id, status, created_at DESC);


-- =====================================================================
-- 4. FUNCTIONS — RLS helpers
--    These are SECURITY DEFINER so the policies can read role/workspace
--    even when RLS would otherwise block the lookup. They MUST exist
--    before the policies in section 6.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.get_user_role()
  RETURNS text
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
AS $function$
  select role from public.users where id = auth.uid()
$function$;

CREATE OR REPLACE FUNCTION public.get_user_workspace_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
AS $function$
  select workspace_id from public.users where id = auth.uid()
$function$;


-- =====================================================================
-- 5. FUNCTIONS — judging system + analytics (used by dashboard-server)
-- =====================================================================

-- BEFORE INSERT/UPDATE on workspaces to ensure config.judging exists.
CREATE OR REPLACE FUNCTION public.ensure_workspace_judging_config()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.config IS NULL THEN
    NEW.config := '{}'::jsonb;
  END IF;

  IF NEW.config->'judging' IS NULL THEN
    NEW.config := jsonb_set(
      NEW.config,
      '{judging}',
      jsonb_build_object(
        'enabled', false,
        'disabled_agent_ids', '[]'::jsonb,
        'max_judged_calls_per_day', 200
      )
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- Per-workspace advisory locks (cluster generator concurrency control).
CREATE OR REPLACE FUNCTION public.jj_try_advisory_lock(p_workspace_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_key1 INT := hashtext('jj_cluster_generator');
  v_key2 INT := hashtext(p_workspace_id::TEXT);
BEGIN
  RETURN pg_try_advisory_lock(v_key1, v_key2);
END;
$function$;

CREATE OR REPLACE FUNCTION public.jj_release_advisory_lock(p_workspace_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_key1 INT := hashtext('jj_cluster_generator');
  v_key2 INT := hashtext(p_workspace_id::TEXT);
BEGIN
  RETURN pg_advisory_unlock(v_key1, v_key2);
END;
$function$;

-- Daily-cap counters: reserve / release a judging slot atomically.
CREATE OR REPLACE FUNCTION public.reserve_judging_slot(p_workspace_id uuid)
  RETURNS json
  LANGUAGE plpgsql
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_enabled BOOLEAN;
  v_limit   INTEGER;
  v_today   DATE := (NOW() AT TIME ZONE 'UTC')::DATE;
  v_count   INTEGER;
BEGIN
  SELECT judging_enabled, max_judged_calls_per_day
    INTO v_enabled, v_limit
  FROM workspaces
  WHERE id = p_workspace_id;

  IF NOT FOUND THEN
    RETURN json_build_object('reserved', false, 'reason', 'workspace not found', 'count', 0, 'limit', 0);
  END IF;

  IF v_enabled IS NOT TRUE THEN
    RETURN json_build_object('reserved', false, 'reason', 'judging_enabled=false', 'count', 0, 'limit', COALESCE(v_limit, 0));
  END IF;

  IF COALESCE(v_limit, 0) <= 0 THEN
    RETURN json_build_object('reserved', false, 'reason', 'cap <= 0', 'count', 0, 'limit', COALESCE(v_limit, 0));
  END IF;

  INSERT INTO workspace_judging_usage (workspace_id, day, count, updated_at)
  VALUES (p_workspace_id, v_today, 1, NOW())
  ON CONFLICT (workspace_id, day) DO UPDATE
    SET count = workspace_judging_usage.count + 1,
        updated_at = NOW()
    WHERE workspace_judging_usage.count < v_limit
  RETURNING count INTO v_count;

  IF v_count IS NULL THEN
    -- Conflict update was blocked by WHERE → cap already hit.
    SELECT count INTO v_count FROM workspace_judging_usage
      WHERE workspace_id = p_workspace_id AND day = v_today;
    RETURN json_build_object('reserved', false, 'reason', 'daily cap reached', 'count', COALESCE(v_count, 0), 'limit', v_limit);
  END IF;

  RETURN json_build_object('reserved', true, 'reason', 'ok', 'count', v_count, 'limit', v_limit);
END;
$function$;

CREATE OR REPLACE FUNCTION public.release_judging_slot(p_workspace_id uuid)
  RETURNS json
  LANGUAGE plpgsql
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_today DATE := (NOW() AT TIME ZONE 'UTC')::DATE;
  v_count INTEGER;
BEGIN
  UPDATE workspace_judging_usage
     SET count = GREATEST(count - 1, 0),
         updated_at = NOW()
   WHERE workspace_id = p_workspace_id AND day = v_today
  RETURNING count INTO v_count;
  RETURN json_build_object('released', FOUND, 'count', COALESCE(v_count, 0));
END;
$function$;

-- Latest weekly batch run for a workspace (dashboard widget).
CREATE OR REPLACE FUNCTION public.latest_batch_run(p_workspace_id uuid)
  RETURNS json
  LANGUAGE sql
  STABLE
  SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT json_build_object(
    'week_start', r.week_start,
    'week_end', r.week_end,
    'status', r.status,
    'call_count', r.call_count,
    'estimated_cost_usd', r.estimated_cost_usd,
    'submitted_at', r.submitted_at,
    'completed_at', r.completed_at
  )
  FROM weekly_batch_runs r
  WHERE r.workspace_id = p_workspace_id
  ORDER BY r.week_start DESC
  LIMIT 1;
$function$;

-- /admin/health agent quality summary.
CREATE OR REPLACE FUNCTION public.agent_quality_summary(p_workspace_id uuid, p_agent_id text, p_since timestamp with time zone)
  RETURNS json
  LANGUAGE plpgsql
  STABLE
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_total_calls INTEGER;
  v_ranked JSON;
  v_signals JSON;
  v_totals JSON;
  v_now TIMESTAMPTZ := NOW();
BEGIN
  -- Total distinct calls JUDGED AND ended within the window.
  SELECT COUNT(DISTINCT cj.call_id) INTO v_total_calls
  FROM call_judgements cj
  JOIN calls c ON c.id = cj.call_id
  WHERE cj.workspace_id = p_workspace_id
    AND cj.agent_id = p_agent_id
    AND c.is_test = false
    AND c.ended_at >= p_since;

  SELECT json_agg(row_to_json(rc)) INTO v_ranked FROM (
    WITH per_rule AS (
      SELECT
        cj.rule_id,
        cj.rule_type,
        COUNT(DISTINCT cj.call_id) AS call_count,
        COUNT(DISTINCT CASE WHEN cj.result = 'violation' THEN cj.call_id END) AS violation_count,
        COUNT(DISTINCT CASE WHEN cj.result = 'warning'   THEN cj.call_id END) AS warning_count,
        MODE() WITHIN GROUP (ORDER BY cj.severity) AS typical_severity,
        COUNT(DISTINCT CASE WHEN cj.result IN ('violation','warning') THEN cj.call_id END)::NUMERIC AS offender_count
      FROM call_judgements cj
      JOIN calls c ON c.id = cj.call_id
      WHERE cj.workspace_id = p_workspace_id
        AND cj.agent_id = p_agent_id
        AND c.is_test = false
        AND c.ended_at >= p_since
        AND cj.result IN ('violation','warning')
      GROUP BY cj.rule_id, cj.rule_type
    )
    SELECT
      pr.rule_id,
      pr.rule_type,
      pr.call_count,
      pr.violation_count,
      pr.warning_count,
      pr.typical_severity,
      ROUND((pr.offender_count / NULLIF(v_total_calls, 0)) * 100, 1) AS frequency_pct,
      ROUND(
        ((pr.offender_count / NULLIF(v_total_calls, 0)) * 100)
        * CASE pr.typical_severity
            WHEN 'high' THEN 3.3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 1
          END, 2
      ) AS rank_score,
      open_c.id AS cluster_id,
      (open_c.regressed_from_cluster_id IS NOT NULL) AS regressed
    FROM per_rule pr
    LEFT JOIN judgement_clusters open_c
      ON open_c.workspace_id = p_workspace_id
     AND open_c.agent_id = p_agent_id
     AND open_c.rule_id = pr.rule_id
     AND open_c.status = 'open'
    WHERE NOT EXISTS (
      SELECT 1 FROM judgement_clusters dc
      WHERE dc.workspace_id = p_workspace_id
        AND dc.agent_id = p_agent_id
        AND dc.rule_id = pr.rule_id
        AND dc.status = 'dismissed'
        AND (dc.dismissed_until IS NULL OR dc.dismissed_until > v_now)
    )
    AND v_total_calls >= 10
    AND (pr.offender_count / NULLIF(v_total_calls, 0)) >= 0.05
    ORDER BY rank_score DESC NULLS LAST
  ) rc;

  SELECT json_agg(row_to_json(s)) INTO v_signals FROM (
    SELECT
      cj.rule_id,
      COUNT(DISTINCT CASE WHEN cj.result = 'signal_fired' THEN cj.call_id END) AS fired_count,
      ROUND(
        (COUNT(DISTINCT CASE WHEN cj.result = 'signal_fired' THEN cj.call_id END)::NUMERIC
         / NULLIF(v_total_calls, 0)) * 100, 1
      ) AS fired_pct
    FROM call_judgements cj
    JOIN calls c ON c.id = cj.call_id
    WHERE cj.workspace_id = p_workspace_id
      AND cj.agent_id = p_agent_id
      AND c.is_test = false
      AND c.ended_at >= p_since
      AND cj.rule_type = 'signal'
    GROUP BY cj.rule_id
    HAVING COUNT(DISTINCT CASE WHEN cj.result = 'signal_fired' THEN cj.call_id END) > 0
    ORDER BY fired_count DESC
  ) s;

  SELECT json_build_object(
    'total_calls_judged', COALESCE(v_total_calls, 0),
    'total_violations', (SELECT COUNT(*) FROM call_judgements cj
       JOIN calls c ON c.id = cj.call_id
      WHERE cj.workspace_id = p_workspace_id AND cj.agent_id = p_agent_id
        AND c.is_test = false AND c.ended_at >= p_since AND cj.result = 'violation'),
    'total_warnings', (SELECT COUNT(*) FROM call_judgements cj
       JOIN calls c ON c.id = cj.call_id
      WHERE cj.workspace_id = p_workspace_id AND cj.agent_id = p_agent_id
        AND c.is_test = false AND c.ended_at >= p_since AND cj.result = 'warning'),
    'total_signals_fired', (SELECT COUNT(*) FROM call_judgements cj
       JOIN calls c ON c.id = cj.call_id
      WHERE cj.workspace_id = p_workspace_id AND cj.agent_id = p_agent_id
        AND c.is_test = false AND c.ended_at >= p_since AND cj.result = 'signal_fired')
  ) INTO v_totals;

  RETURN json_build_object(
    'agent_id', p_agent_id,
    'workspace_id', p_workspace_id,
    'since', p_since,
    'totals', v_totals,
    'ranked_clusters', COALESCE(v_ranked, '[]'::JSON),
    'signals', COALESCE(v_signals, '[]'::JSON)
  );
END;
$function$;

-- /admin/health rule weekly trend (12-week default).
CREATE OR REPLACE FUNCTION public.rule_weekly_series(p_workspace_id uuid, p_agent_id text, p_rule_id text, p_weeks integer DEFAULT 12)
  RETURNS json
  LANGUAGE plpgsql
  STABLE
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_series JSON;
  v_fixes JSON;
BEGIN
  WITH weeks AS (
    SELECT
      date_trunc('week', NOW()::timestamp) - (n * INTERVAL '1 week') AS week_start,
      date_trunc('week', NOW()::timestamp) - (n * INTERVAL '1 week') + INTERVAL '7 days' - INTERVAL '1 second' AS week_end
    FROM generate_series(0, p_weeks - 1) n
  ),
  week_fix AS (
    SELECT
      w.week_start,
      w.week_end,
      (SELECT MAX(deployed_at) FROM judgement_fixes
         WHERE workspace_id = p_workspace_id
           AND agent_id = p_agent_id
           AND rule_id = p_rule_id
           AND reverted_at IS NULL
           AND deployed_at <= w.week_end) AS latest_fix
    FROM weeks w
  ),
  week_data AS (
    SELECT
      wf.week_start,
      wf.week_end,
      GREATEST(wf.week_start::timestamp, COALESCE(wf.latest_fix, wf.week_start::timestamp)) AS effective_start,
      wf.latest_fix
    FROM week_fix wf
  ),
  series_rows AS (
    SELECT
      wd.week_start::DATE AS week,
      wd.effective_start,
      wd.latest_fix,
      COUNT(DISTINCT cj.call_id) FILTER (WHERE c.ended_at >= wd.effective_start) AS calls_judged,
      COUNT(DISTINCT cj.call_id) FILTER (WHERE c.ended_at >= wd.effective_start AND cj.result IN ('violation','warning')) AS violating_calls,
      COUNT(DISTINCT cj.call_id) FILTER (WHERE c.ended_at >= wd.effective_start AND cj.result = 'violation') AS violations,
      COUNT(DISTINCT cj.call_id) FILTER (WHERE c.ended_at >= wd.effective_start AND cj.result = 'warning') AS warnings
    FROM week_data wd
    LEFT JOIN call_judgements cj
      ON cj.workspace_id = p_workspace_id
     AND cj.agent_id = p_agent_id
     AND cj.rule_id = p_rule_id
    LEFT JOIN calls c
      ON c.id = cj.call_id
     AND c.is_test = false
     AND c.ended_at >= wd.week_start
     AND c.ended_at <= wd.week_end
    GROUP BY wd.week_start, wd.effective_start, wd.latest_fix
    ORDER BY wd.week_start DESC
  )
  SELECT json_agg(json_build_object(
    'week', week,
    'effective_start', effective_start,
    'fix_in_effect_at', latest_fix,
    'calls_judged', calls_judged,
    'violating_calls', violating_calls,
    'violations', violations,
    'warnings', warnings,
    'violation_pct',
      CASE WHEN calls_judged > 0
        THEN ROUND((violating_calls::NUMERIC / calls_judged) * 100, 1)
        ELSE NULL END
  )) INTO v_series FROM series_rows;

  SELECT json_agg(json_build_object(
    'id', id,
    'deployed_at', deployed_at,
    'reverted_at', reverted_at,
    'description', description,
    'change_type', change_type
  ) ORDER BY deployed_at) INTO v_fixes
  FROM judgement_fixes
  WHERE workspace_id = p_workspace_id
    AND agent_id = p_agent_id
    AND rule_id = p_rule_id
    AND deployed_at >= NOW() - (p_weeks * INTERVAL '1 week');

  RETURN json_build_object(
    'workspace_id', p_workspace_id,
    'agent_id', p_agent_id,
    'rule_id', p_rule_id,
    'weeks_requested', p_weeks,
    'series', COALESCE(v_series, '[]'::JSON),
    'fixes', COALESCE(v_fixes, '[]'::JSON)
  );
END;
$function$;


-- =====================================================================
-- 6. TRIGGERS
-- =====================================================================

DROP TRIGGER IF EXISTS workspaces_ensure_judging_config ON public.workspaces;
CREATE TRIGGER workspaces_ensure_judging_config
  BEFORE INSERT OR UPDATE ON public.workspaces
  FOR EACH ROW
  EXECUTE FUNCTION public.ensure_workspace_judging_config();


-- =====================================================================
-- 7. ROW LEVEL SECURITY
-- =====================================================================

-- Enable RLS on every customer-facing table. reclassify_jobs intentionally
-- runs WITHOUT RLS in prod (service-role-only writer/reader); mirroring that.
ALTER TABLE public.workspaces             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calls                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_errors        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feedback               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.call_saves             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.call_judgements        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.judgement_clusters     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.judgement_fixes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workspace_judging_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_batch_runs      ENABLE ROW LEVEL SECURITY;
-- reclassify_jobs: RLS DISABLED (service-role only, mirrors prod).


-- ---------- workspaces ----------
DROP POLICY IF EXISTS workspace_select ON public.workspaces;
CREATE POLICY workspace_select ON public.workspaces
  FOR SELECT TO public
  USING ((id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));


-- ---------- users ----------
DROP POLICY IF EXISTS users_select ON public.users;
CREATE POLICY users_select ON public.users
  FOR SELECT TO public
  USING ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));


-- ---------- calls ----------
DROP POLICY IF EXISTS calls_select ON public.calls;
CREATE POLICY calls_select ON public.calls
  FOR SELECT TO public
  USING ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));


-- ---------- workflow_errors (superadmin-read-only) ----------
DROP POLICY IF EXISTS errors_superadmin ON public.workflow_errors;
CREATE POLICY errors_superadmin ON public.workflow_errors
  FOR SELECT TO public
  USING (get_user_role() = 'superadmin'::text);


-- ---------- feedback ----------
DROP POLICY IF EXISTS feedback_select ON public.feedback;
CREATE POLICY feedback_select ON public.feedback
  FOR SELECT TO public
  USING ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));

DROP POLICY IF EXISTS feedback_insert ON public.feedback;
CREATE POLICY feedback_insert ON public.feedback
  FOR INSERT TO public
  WITH CHECK ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));

DROP POLICY IF EXISTS feedback_update ON public.feedback;
CREATE POLICY feedback_update ON public.feedback
  FOR UPDATE TO public
  USING ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));


-- ---------- call_saves ----------
DROP POLICY IF EXISTS call_saves_select ON public.call_saves;
CREATE POLICY call_saves_select ON public.call_saves
  FOR SELECT TO public
  USING (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND (u.role = 'superadmin'::text OR u.workspace_id = call_saves.workspace_id)
  ));

DROP POLICY IF EXISTS call_saves_insert ON public.call_saves;
CREATE POLICY call_saves_insert ON public.call_saves
  FOR INSERT TO public
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND (u.role = 'superadmin'::text OR u.workspace_id = call_saves.workspace_id)
    )
  );

DROP POLICY IF EXISTS call_saves_update ON public.call_saves;
CREATE POLICY call_saves_update ON public.call_saves
  FOR UPDATE TO public
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS call_saves_delete ON public.call_saves;
CREATE POLICY call_saves_delete ON public.call_saves
  FOR DELETE TO public
  USING (
    auth.uid() = user_id
    OR EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
    )
  );


-- ---------- call_judgements (superadmin-only) ----------
DROP POLICY IF EXISTS call_judgements_select_superadmin ON public.call_judgements;
CREATE POLICY call_judgements_select_superadmin ON public.call_judgements
  FOR SELECT TO public
  USING (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
  ));

DROP POLICY IF EXISTS call_judgements_service_insert ON public.call_judgements;
CREATE POLICY call_judgements_service_insert ON public.call_judgements
  FOR INSERT TO public
  WITH CHECK (get_user_role() = 'superadmin'::text);


-- ---------- judgement_clusters (superadmin-only) ----------
DROP POLICY IF EXISTS judgement_clusters_select_superadmin ON public.judgement_clusters;
CREATE POLICY judgement_clusters_select_superadmin ON public.judgement_clusters
  FOR SELECT TO public
  USING (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
  ));

DROP POLICY IF EXISTS judgement_clusters_service_insert ON public.judgement_clusters;
CREATE POLICY judgement_clusters_service_insert ON public.judgement_clusters
  FOR INSERT TO public
  WITH CHECK (get_user_role() = 'superadmin'::text);

DROP POLICY IF EXISTS judgement_clusters_update_superadmin ON public.judgement_clusters;
CREATE POLICY judgement_clusters_update_superadmin ON public.judgement_clusters
  FOR UPDATE TO public
  USING (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
  ));


-- ---------- judgement_fixes (superadmin-only) ----------
DROP POLICY IF EXISTS judgement_fixes_select_superadmin ON public.judgement_fixes;
CREATE POLICY judgement_fixes_select_superadmin ON public.judgement_fixes
  FOR SELECT TO public
  USING (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
  ));

DROP POLICY IF EXISTS judgement_fixes_insert_superadmin ON public.judgement_fixes;
CREATE POLICY judgement_fixes_insert_superadmin ON public.judgement_fixes
  FOR INSERT TO public
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'superadmin'::text
  ));


-- ---------- workspace_judging_usage ----------
DROP POLICY IF EXISTS workspace_judging_usage_select ON public.workspace_judging_usage;
CREATE POLICY workspace_judging_usage_select ON public.workspace_judging_usage
  FOR SELECT TO public
  USING ((workspace_id = get_user_workspace_id()) OR (get_user_role() = 'superadmin'::text));


-- ---------- weekly_batch_runs (superadmin-only, restricted to authenticated) ----------
DROP POLICY IF EXISTS weekly_batch_runs_superadmin_read ON public.weekly_batch_runs;
CREATE POLICY weekly_batch_runs_superadmin_read ON public.weekly_batch_runs
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.users
    WHERE users.id = auth.uid() AND users.role = 'superadmin'::text
  ));


-- =====================================================================
-- DONE.
-- =====================================================================
