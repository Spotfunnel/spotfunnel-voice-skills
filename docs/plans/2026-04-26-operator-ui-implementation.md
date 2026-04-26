# ZeroOnboarding Operator UI — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Build the operator UI for ZeroOnboarding — a cloud-hosted Next.js dashboard at a Vercel URL where Leo + collaborators read all `/base-agent`-generated artifacts, highlight problems, and feed corrections back through a 3-tier protocol-improvement loop (annotations → feedback → lessons → prompts).

**Architecture:** Next.js (App Router) on Vercel + Supabase Postgres (`operator_ui` schema) + local Python skill rewritten to write via Supabase REST. Vercel password protection. No local file system as data source. See [`docs/plans/2026-04-26-operator-ui-design.md`](./2026-04-26-operator-ui-design.md) for the full design.

**Tech Stack:** Next.js 15+ (App Router, TypeScript), Tailwind CSS, `react-markdown` + `remark-gfm`, TanStack Query, Supabase JS client, Supabase Postgres, Python 3.11+ (skill backend), `httpx` + `respx` (Python tests), Playwright (UI tests), `pytest`.

---

## Conventions

- **Repo path during this work:** `c:/Users/leoge/Code/spotfunnel-voice-skills/` until the rename happens, then `c:/Users/leoge/Code/ZeroOnboarding/`. Plan tasks reference both — use whichever exists.
- **Branch strategy:** main only. Frequent commits.
- **Test-first:** every task starts with a failing test (where applicable), then minimal implementation, then verify pass, then commit.
- **Commit message style:** `<type>(<scope>): <imperative summary>` matching the existing repo (e.g. `feat(ui)`, `feat(skill)`, `fix(verify)`, `docs`).
- **Co-author footer:** add `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` to every commit.

---

# Phase 0 — Pre-flight (manual, before code)

### Task 0.1: Rename GitHub repo

**Steps (manual):**
1. Go to `https://github.com/Spotfunnel/spotfunnel-voice-skills/settings`.
2. Rename repo to `ZeroOnboarding`. GitHub auto-redirects old URL.
3. On local machine: `cd c:/Users/leoge/Code/ && mv spotfunnel-voice-skills ZeroOnboarding`.
4. Update remote: `cd ZeroOnboarding && git remote set-url origin https://github.com/Spotfunnel/ZeroOnboarding.git`.
5. Verify: `git fetch && git status` — should be clean.

**No commit** — just a rename.

### Task 0.2: Provision Supabase schema

**Steps (manual via Supabase SQL editor or CLI):**
1. Connect to existing Supabase project (the one with the customer dashboard already provisioned).
2. Open SQL Editor in Supabase dashboard.
3. Paste the schema from the design doc's "Data model" section (creates `operator_ui` schema + 7 tables + RLS + indexes).
4. Run. Verify all tables exist via `Table Editor`.

This becomes Task 1.1 below — track it there with a migration file in the repo.

### Task 0.3: Create Vercel project

**Steps (manual):**
1. `vercel.com` → New Project → Import `Spotfunnel/ZeroOnboarding`.
2. Set root directory to `ui/web` (Next.js app — not yet existing).
3. Don't deploy yet (no code).
4. In Project Settings → Deployment Protection → enable Password Protection. Set password to `Walkergewert0!`.
5. Add env vars: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`. Values copied from existing Supabase project's API settings.

### Task 0.4: Local `.env` updates for skill backend

**Files:**
- Modify: `.env` (local, never committed)
- Modify: `.env.example` (committed)

**Step 1:** Add to local `.env`:
```
SUPABASE_OPERATOR_URL=https://<project-ref>.supabase.co
SUPABASE_OPERATOR_SERVICE_ROLE_KEY=<service-role-key-from-supabase-dashboard>
USE_SUPABASE_BACKEND=0
```

(Feature flag starts at `0` — flips to `1` after Phase 4 cutover.)

**Step 2:** Add to `.env.example`:
```
# Operator UI (Phase 4+)
SUPABASE_OPERATOR_URL=
SUPABASE_OPERATOR_SERVICE_ROLE_KEY=
USE_SUPABASE_BACKEND=0
```

**Step 3 — Commit:**
```bash
git add .env.example
git commit -m "chore(env): add operator UI Supabase env vars (feature-flagged)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 1 — Cloud foundation

## M1: Supabase schema + RLS + indexes

### Task 1.1: Create migration file

**Files:**
- Create: `migrations/operator_ui_schema.sql`

**Step 1:** Write the SQL migration. Full content per design doc's data model section:

```sql
-- migrations/operator_ui_schema.sql
-- Operator UI schema. Read at every /base-agent run + refine.

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

-- RLS — permissive within schema; access gated by Vercel password (humans) and service-role key (skill)
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
```

**Step 2:** Apply migration via Supabase SQL Editor. Verify all 7 tables exist + indexes via the table editor.

**Step 3:** Smoke test — run a sanity insert/read in Supabase SQL Editor:
```sql
insert into operator_ui.customers (slug, name) values ('test-001', 'Test Customer');
select * from operator_ui.customers;
delete from operator_ui.customers where slug = 'test-001';
```
Expected: insert succeeds, select returns 1 row, delete succeeds.

**Step 4 — Commit:**
```bash
git add migrations/operator_ui_schema.sql
git commit -m "feat(db): operator_ui schema — 7 tables, RLS, indexes for operator UI

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: Schema round-trip integration test

**Files:**
- Create: `ui/server/tests/__init__.py`
- Create: `ui/server/tests/test_schema_roundtrip.py`

**Step 1:** Write failing test:
```python
# ui/server/tests/test_schema_roundtrip.py
import os
import pytest
from uuid import uuid4
import httpx

SUPABASE_URL = os.environ["SUPABASE_OPERATOR_URL"]
SERVICE_KEY = os.environ["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"]

HEADERS = {
    "apikey": SERVICE_KEY,
    "Authorization": f"Bearer {SERVICE_KEY}",
    "Content-Type": "application/json",
    "Prefer": "return=representation",
}

REST = f"{SUPABASE_URL}/rest/v1"

def _post(table: str, body: dict) -> dict:
    r = httpx.post(f"{REST}/{table}", json=body, headers={**HEADERS, "Accept-Profile": "operator_ui", "Content-Profile": "operator_ui"})
    r.raise_for_status()
    return r.json()[0]

def _delete(table: str, slug: str):
    httpx.delete(f"{REST}/{table}?slug=eq.{slug}", headers={**HEADERS, "Accept-Profile": "operator_ui", "Content-Profile": "operator_ui"})

def test_customer_roundtrip():
    slug = f"test-{uuid4().hex[:8]}"
    created = _post("customers", {"slug": slug, "name": "Test Customer"})
    assert created["slug"] == slug
    assert created["id"]
    _delete("customers", slug)
```

**Step 2:** Run test, expect pass:
```bash
cd ui/server && python -m pytest tests/test_schema_roundtrip.py -v
```
Expected: PASS (schema is already created in Task 1.1).

**Step 3 — Commit:**
```bash
git add ui/server/tests/test_schema_roundtrip.py ui/server/tests/__init__.py
git commit -m "test(db): schema round-trip integration test

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M2: Next.js skeleton + Vercel deploy

### Task 2.1: Initialize Next.js app

**Files:**
- Create: `ui/web/` (entire Next.js project structure)

**Step 1:** Run scaffold:
```bash
cd c:/Users/leoge/Code/spotfunnel-voice-skills
mkdir -p ui
cd ui
pnpm dlx create-next-app@latest web --typescript --tailwind --app --src-dir --import-alias "@/*" --no-eslint --no-src-dir
```

(Adjust based on prompt answers — App Router, TypeScript, Tailwind, no `src/` dir.)

**Step 2:** Install additional deps:
```bash
cd web
pnpm add @supabase/supabase-js @supabase/ssr @tanstack/react-query react-markdown remark-gfm rehype-raw
pnpm add -D @types/node
```

**Step 3:** Create Supabase client utility:

**File:** `ui/web/lib/supabase.ts`
```typescript
import { createClient } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

// Server-side client for Server Components — uses anon key (RLS gated)
export function getServerSupabase() {
  const cookieStore = cookies();
  return createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      get: (n) => cookieStore.get(n)?.value,
      set: () => {},
      remove: () => {},
    },
    db: { schema: "operator_ui" },
  });
}

// Browser-side client
export const browserSupabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "operator_ui" },
});
```

**Step 4:** Replace default `app/page.tsx` with placeholder:
```typescript
// ui/web/app/page.tsx
export default function Home() {
  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <h1 className="text-3xl font-medium">ZeroOnboarding</h1>
      <p className="mt-4 text-[#6B6B6B]">Operator UI — coming online.</p>
    </main>
  );
}
```

**Step 5:** Test locally:
```bash
cd ui/web && pnpm dev
```
Expected: open `http://localhost:3000` → see "ZeroOnboarding" + "Operator UI — coming online."

**Step 6:** Commit:
```bash
git add ui/web
git commit -m "feat(ui): Next.js skeleton + Supabase client + placeholder home

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Configure Vercel deployment

**Files:**
- Create: `vercel.json` (in repo root)
- Modify: `.gitignore`

**Step 1:** Create `vercel.json`:
```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "nextjs",
  "buildCommand": "cd ui/web && pnpm build",
  "outputDirectory": "ui/web/.next",
  "installCommand": "cd ui/web && pnpm install"
}
```

**Step 2:** Update `.gitignore`:
```
# UI
ui/web/.next/
ui/web/node_modules/
ui/web/.env.local
ui/server/.venv/
```

**Step 3:** Deploy via Vercel CLI:
```bash
pnpm dlx vercel --prod
```
Expected: deploy succeeds, URL prints. Open URL → password gate appears → enter `Walkergewert0!` → see placeholder.

**Step 4:** Commit:
```bash
git add vercel.json .gitignore
git commit -m "feat(deploy): Vercel project config + gitignore for ui/

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 2 — Read-only viewer

## M3: Customer list page

### Task 3.1: Customer list — failing Playwright test

**Files:**
- Create: `ui/web/tests/e2e/customer-list.spec.ts`

**Step 1:** Install Playwright:
```bash
cd ui/web && pnpm add -D @playwright/test && pnpm dlx playwright install chromium
```

**Step 2:** Seed Supabase with two test customers:
```sql
-- Run in Supabase SQL Editor
insert into operator_ui.customers (slug, name) values
  ('test-customer-a', 'Customer A'),
  ('test-customer-b', 'Customer B');
```

**Step 3:** Write failing test:
```typescript
// ui/web/tests/e2e/customer-list.spec.ts
import { test, expect } from "@playwright/test";

test("customer list renders both customers from Supabase", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Customer A" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Customer B" })).toBeVisible();
});
```

**Step 4:** Create `playwright.config.ts`:
```typescript
import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  use: { baseURL: "http://localhost:3000" },
  webServer: { command: "pnpm dev", port: 3000, reuseExistingServer: true },
});
```

**Step 5:** Run, expect FAIL:
```bash
pnpm exec playwright test
```
Expected: timeout, no "Customer A" found.

### Task 3.2: Customer list — implementation

**Files:**
- Modify: `ui/web/app/page.tsx`
- Create: `ui/web/components/CustomerCard.tsx`

**Step 1:** Implement `app/page.tsx` (Server Component):
```typescript
import { getServerSupabase } from "@/lib/supabase";
import { CustomerCard } from "@/components/CustomerCard";

export default async function Home() {
  const supabase = getServerSupabase();
  const { data: customers } = await supabase
    .from("customers")
    .select("id, slug, name, created_at")
    .order("created_at", { ascending: false });

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <h1 className="text-3xl font-medium">ZeroOnboarding</h1>
      <div className="mt-12 space-y-6 max-w-3xl">
        {(customers || []).map((c) => <CustomerCard key={c.id} customer={c} />)}
      </div>
    </main>
  );
}
```

**Step 2:** Implement `CustomerCard`:
```typescript
import Link from "next/link";

export function CustomerCard({ customer }: { customer: { slug: string; name: string } }) {
  return (
    <Link href={`/c/${customer.slug}`} className="block p-6 border-b border-[#E5E5E0] hover:bg-white transition-colors">
      <h2 className="text-2xl font-medium">{customer.name}</h2>
      <p className="mt-1 text-sm text-[#6B6B6B] font-mono">{customer.slug}</p>
    </Link>
  );
}
```

**Step 3:** Run test, expect PASS:
```bash
pnpm exec playwright test
```

**Step 4 — Commit:**
```bash
git add ui/web
git commit -m "feat(ui): customer list page reads from Supabase

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M4: Customer page (artifact roster)

### Task 4.1: Seed test data

**Step 1:** Insert test customer with one run + 7 artifacts:
```sql
-- Supabase SQL Editor
insert into operator_ui.customers (id, slug, name) values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'test-roster', 'Roster Test');

insert into operator_ui.runs (id, customer_id, slug_with_ts, started_at, state, stage_complete) values
  ('22222222-2222-2222-2222-222222222222'::uuid, '11111111-1111-1111-1111-111111111111'::uuid,
   'test-roster-2026-04-26T00-00-00Z', now(), '{}'::jsonb, 11);

-- Insert all 7 artifacts (use real markdown/text content, abbreviated here)
insert into operator_ui.artifacts (run_id, artifact_name, content, size_bytes) values
  ('22222222-2222-2222-2222-222222222222'::uuid, 'brain-doc', '# Roster Test\n\nBrain doc body.', 33),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'system-prompt', 'System prompt...', 16),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'discovery-prompt', 'Discovery...', 12),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'customer-context', 'Context...', 10),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'cover-email', 'Email...', 8),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'meeting-transcript', 'Transcript...', 11);
```

### Task 4.2: Customer page failing test

**Files:**
- Create: `ui/web/tests/e2e/customer-page.spec.ts`

**Step 1:** Write test:
```typescript
import { test, expect } from "@playwright/test";

test("customer page shows 7-chapter roster", async ({ page }) => {
  await page.goto("/c/test-roster");
  await expect(page.getByText("Roster Test")).toBeVisible();
  for (const chapter of ["Brain doc", "System prompt", "Discovery prompt", "Customer context", "Cover email", "Meeting transcript"]) {
    await expect(page.getByText(chapter)).toBeVisible();
  }
});
```

**Step 2:** Run, expect FAIL (404 — route not yet defined).

### Task 4.3: Customer page implementation

**Files:**
- Create: `ui/web/app/c/[slug]/page.tsx`

**Step 1:** Implement:
```typescript
import { getServerSupabase } from "@/lib/supabase";
import Link from "next/link";
import { notFound } from "next/navigation";

const ARTIFACT_ORDER = [
  { key: "brain-doc", title: "Brain doc" },
  { key: "system-prompt", title: "System prompt" },
  { key: "discovery-prompt", title: "Discovery prompt" },
  { key: "customer-context", title: "Customer context" },
  { key: "cover-email", title: "Cover email" },
  { key: "meeting-transcript", title: "Meeting transcript" },
];

export default async function CustomerPage({ params }: { params: { slug: string } }) {
  const supabase = getServerSupabase();
  const { data: customer } = await supabase.from("customers").select("*").eq("slug", params.slug).maybeSingle();
  if (!customer) notFound();

  const { data: latestRun } = await supabase
    .from("runs")
    .select("id, started_at, stage_complete")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: artifacts } = await supabase
    .from("artifacts")
    .select("artifact_name")
    .eq("run_id", latestRun?.id || "");

  const present = new Set((artifacts || []).map((a) => a.artifact_name));

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A] max-w-3xl mx-auto">
      <h1 className="text-3xl font-medium">{customer.name}</h1>
      <hr className="my-4 border-[#E5E5E0]" />
      {latestRun && (
        <p className="text-sm text-[#6B6B6B]">
          Latest run · {new Date(latestRun.started_at).toLocaleDateString()} · stage {latestRun.stage_complete}/11
        </p>
      )}

      <h2 className="mt-12 text-xs uppercase tracking-wider text-[#6B6B6B]">Read</h2>
      <ol className="mt-6 space-y-3">
        {ARTIFACT_ORDER.map((a, i) => (
          <li key={a.key}>
            {present.has(a.key) ? (
              <Link href={`/c/${params.slug}/${a.key}`} className="flex items-baseline gap-4 hover:underline">
                <span className="text-[#6B6B6B] w-6">{i + 1}.</span>
                <span className="text-lg">{a.title}</span>
              </Link>
            ) : (
              <span className="flex items-baseline gap-4 text-[#6B6B6B]">
                <span className="w-6">{i + 1}.</span>
                <span className="text-lg">{a.title}</span>
                <span className="text-xs">— not yet generated</span>
              </span>
            )}
          </li>
        ))}
      </ol>
    </main>
  );
}
```

**Step 2:** Run test, expect PASS.

**Step 3 — Commit:**
```bash
git add ui/web
git commit -m "feat(ui): customer page with artifact roster reads from Supabase

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M5: Reading mode (artifact viewer)

### Task 5.1: Failing test

**Files:**
- Modify: `ui/web/tests/e2e/customer-page.spec.ts` (add)

```typescript
test("clicking brain doc opens reading mode", async ({ page }) => {
  await page.goto("/c/test-roster");
  await page.getByText("Brain doc").click();
  await expect(page).toHaveURL("/c/test-roster/brain-doc");
  await expect(page.getByRole("heading", { name: "Roster Test", level: 1 })).toBeVisible();
});
```

Run, expect FAIL.

### Task 5.2: Reading mode implementation

**Files:**
- Create: `ui/web/app/c/[slug]/[artifact]/page.tsx`

**Step 1:** Implement:
```typescript
import { getServerSupabase } from "@/lib/supabase";
import Link from "next/link";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

const ARTIFACT_TITLES: Record<string, string> = {
  "brain-doc": "Brain doc",
  "system-prompt": "System prompt",
  "discovery-prompt": "Discovery prompt",
  "customer-context": "Customer context",
  "cover-email": "Cover email",
  "meeting-transcript": "Meeting transcript",
};

export default async function ArtifactPage({ params }: { params: { slug: string; artifact: string } }) {
  const supabase = getServerSupabase();
  const { data: customer } = await supabase.from("customers").select("id, name").eq("slug", params.slug).maybeSingle();
  if (!customer) notFound();

  const { data: latestRun } = await supabase
    .from("runs").select("id").eq("customer_id", customer.id).order("started_at", { ascending: false }).limit(1).maybeSingle();
  if (!latestRun) notFound();

  const { data: artifact } = await supabase
    .from("artifacts").select("content").eq("run_id", latestRun.id).eq("artifact_name", params.artifact).maybeSingle();
  if (!artifact) notFound();

  const title = ARTIFACT_TITLES[params.artifact] || params.artifact;

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <header className="max-w-3xl mx-auto text-sm text-[#6B6B6B]">
        <Link href={`/c/${params.slug}`} className="hover:underline">← {customer.name}</Link>
        <span className="mx-2">·</span>
        <span>{title}</span>
      </header>
      <article className="mt-8 max-w-3xl mx-auto prose prose-stone font-serif">
        <ReactMarkdown remarkPlugins={[remarkGfm]}>{artifact.content}</ReactMarkdown>
      </article>
    </main>
  );
}
```

**Step 2:** Add Tailwind typography plugin:
```bash
cd ui/web && pnpm add -D @tailwindcss/typography
```

Update `tailwind.config.ts`:
```typescript
plugins: [require("@tailwindcss/typography")],
```

**Step 3:** Run test, expect PASS.

**Step 4 — Commit:**
```bash
git add ui/web
git commit -m "feat(ui): reading mode renders artifact markdown as serif prose

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 3 — Annotation flow

## M6: Drag-to-select + Comment popover + save

### Task 6.1: Highlight library

**Files:**
- Create: `ui/web/lib/highlight.ts`

**Step 1:** Implement Hypothesis-style anchor:
```typescript
// ui/web/lib/highlight.ts
export type AnnotationAnchor = {
  quote: string;
  prefix: string;
  suffix: string;
  charStart: number;
  charEnd: number;
};

const CONTEXT_LEN = 40;

export function captureSelection(rootEl: HTMLElement): AnnotationAnchor | null {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
  const range = sel.getRangeAt(0);
  if (!rootEl.contains(range.commonAncestorContainer)) return null;

  const fullText = rootEl.textContent || "";
  // Compute char offsets
  const beforeRange = range.cloneRange();
  beforeRange.setStart(rootEl, 0);
  beforeRange.setEnd(range.startContainer, range.startOffset);
  const charStart = beforeRange.toString().length;
  const charEnd = charStart + range.toString().length;
  const quote = fullText.slice(charStart, charEnd).trim();
  if (!quote) return null;

  return {
    quote,
    prefix: fullText.slice(Math.max(0, charStart - CONTEXT_LEN), charStart),
    suffix: fullText.slice(charEnd, charEnd + CONTEXT_LEN),
    charStart,
    charEnd,
  };
}
```

### Task 6.2: Comment popover component

**Files:**
- Create: `ui/web/components/CommentPopover.tsx`

**Step 1:** Implement:
```typescript
"use client";
import { useState } from "react";
import { browserSupabase } from "@/lib/supabase";
import type { AnnotationAnchor } from "@/lib/highlight";

export function CommentPopover({
  anchor,
  runId,
  artifactName,
  onSaved,
  onCancel,
}: {
  anchor: AnnotationAnchor;
  runId: string;
  artifactName: string;
  onSaved: () => void;
  onCancel: () => void;
}) {
  const [comment, setComment] = useState("");
  const [saving, setSaving] = useState(false);

  async function save() {
    setSaving(true);
    const authorName = localStorage.getItem("operatorName") || "anonymous";
    const { error } = await browserSupabase.from("annotations").insert({
      run_id: runId,
      artifact_name: artifactName,
      quote: anchor.quote,
      prefix: anchor.prefix,
      suffix: anchor.suffix,
      char_start: anchor.charStart,
      char_end: anchor.charEnd,
      comment,
      author_name: authorName,
    });
    setSaving(false);
    if (error) {
      alert("Save failed: " + error.message);
      return;
    }
    onSaved();
  }

  return (
    <div className="fixed right-8 top-32 w-80 p-4 bg-white border border-[#E5E5E0] shadow-sm">
      <p className="text-sm font-serif text-[#6B6B6B] italic mb-3">"{anchor.quote.slice(0, 80)}{anchor.quote.length > 80 ? "..." : ""}"</p>
      <textarea
        autoFocus
        className="w-full text-sm border border-[#E5E5E0] p-2 resize-none"
        rows={4}
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) save();
          if (e.key === "Escape") onCancel();
        }}
      />
      <div className="mt-3 flex gap-3 text-sm">
        <button onClick={save} disabled={!comment.trim() || saving} className="text-[#2563EB] hover:underline disabled:text-[#6B6B6B]">
          {saving ? "Saving..." : "Save (Ctrl+Enter)"}
        </button>
        <button onClick={onCancel} className="text-[#6B6B6B] hover:underline">Cancel (Esc)</button>
      </div>
    </div>
  );
}
```

### Task 6.3: ArtifactViewer client component with selection

**Files:**
- Create: `ui/web/components/ArtifactViewer.tsx`
- Modify: `ui/web/app/c/[slug]/[artifact]/page.tsx`

**Step 1:** Implement viewer:
```typescript
"use client";
import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { captureSelection, type AnnotationAnchor } from "@/lib/highlight";
import { CommentPopover } from "./CommentPopover";

export function ArtifactViewer({
  content,
  runId,
  artifactName,
  initialAnnotations,
}: {
  content: string;
  runId: string;
  artifactName: string;
  initialAnnotations: Array<{ id: string; quote: string; prefix: string; suffix: string; char_start: number; char_end: number; comment: string }>;
}) {
  const rootRef = useRef<HTMLDivElement>(null);
  const [pendingAnchor, setPendingAnchor] = useState<AnnotationAnchor | null>(null);
  const [popoverPos, setPopoverPos] = useState<{ x: number; y: number } | null>(null);

  function onMouseUp() {
    if (!rootRef.current) return;
    const anchor = captureSelection(rootRef.current);
    if (!anchor) {
      setPopoverPos(null);
      return;
    }
    const range = window.getSelection()!.getRangeAt(0);
    const rect = range.getBoundingClientRect();
    setPopoverPos({ x: rect.right + 8, y: rect.top - 4 });
    setPendingAnchor(anchor);
  }

  return (
    <>
      <div ref={rootRef} onMouseUp={onMouseUp} className="prose prose-stone font-serif max-w-none">
        <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
      </div>
      {pendingAnchor && popoverPos && !document.body.contains(document.querySelector('[data-comment-popover]')) && (
        <button
          data-comment-popover-trigger
          style={{ position: "fixed", left: popoverPos.x, top: popoverPos.y }}
          className="px-3 py-1 text-xs bg-[#1A1A1A] text-white rounded-full"
          onClick={() => setPopoverPos(null) /* show popover via state below */}
        >
          Comment
        </button>
      )}
      {pendingAnchor && (
        <CommentPopover
          anchor={pendingAnchor}
          runId={runId}
          artifactName={artifactName}
          onSaved={() => {
            setPendingAnchor(null);
            window.location.reload(); // M6 simplification — real impl uses router.refresh
          }}
          onCancel={() => setPendingAnchor(null)}
        />
      )}
    </>
  );
}
```

**Step 2:** Update reading-mode page to pass annotations + use the client component:
```typescript
// Modify ui/web/app/c/[slug]/[artifact]/page.tsx
// Replace the <article> body with:
import { ArtifactViewer } from "@/components/ArtifactViewer";

// ... after fetching artifact ...
const { data: annotations } = await supabase
  .from("annotations")
  .select("*")
  .eq("run_id", latestRun.id)
  .eq("artifact_name", params.artifact)
  .eq("status", "open");

return (
  <main className="min-h-screen p-12 bg-[#FAFAF7]">
    <header className="max-w-3xl mx-auto text-sm text-[#6B6B6B]">...</header>
    <article className="mt-8 max-w-3xl mx-auto">
      <ArtifactViewer content={artifact.content} runId={latestRun.id} artifactName={params.artifact} initialAnnotations={annotations || []} />
    </article>
  </main>
);
```

### Task 6.4: First-visit operator-name prompt

**Files:**
- Create: `ui/web/components/OperatorNameGate.tsx`
- Modify: `ui/web/app/layout.tsx`

**Step 1:** Implement:
```typescript
"use client";
import { useEffect, useState } from "react";

export function OperatorNameGate({ children }: { children: React.ReactNode }) {
  const [name, setName] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  useEffect(() => setName(localStorage.getItem("operatorName")), []);
  if (name === null) return null; // server render fallback
  if (!name) {
    return (
      <div className="min-h-screen flex items-center justify-center p-12 bg-[#FAFAF7]">
        <div className="max-w-sm w-full">
          <h2 className="text-lg font-medium">Your name</h2>
          <p className="mt-1 text-sm text-[#6B6B6B]">Used to label your annotations. Stored locally.</p>
          <input autoFocus value={draft} onChange={(e) => setDraft(e.target.value)} className="mt-4 w-full border border-[#E5E5E0] p-2" />
          <button
            disabled={!draft.trim()}
            onClick={() => {
              localStorage.setItem("operatorName", draft.trim());
              setName(draft.trim());
            }}
            className="mt-3 px-4 py-2 text-sm bg-[#1A1A1A] text-white disabled:bg-[#6B6B6B]"
          >
            Save
          </button>
        </div>
      </div>
    );
  }
  return <>{children}</>;
}
```

**Step 2:** Wrap layout with it.

### Task 6.5: Test annotation save round-trip

**Files:**
- Create: `ui/web/tests/e2e/annotations.spec.ts`

**Step 1:**
```typescript
import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("operatorName", "test-operator"));
});

test("highlight + comment + save persists", async ({ page }) => {
  await page.goto("/c/test-roster/brain-doc");
  // Triple-click to select line
  await page.getByText("Brain doc body.").click({ clickCount: 3 });
  await page.getByRole("button", { name: "Comment" }).click();
  await page.locator("textarea").fill("test comment from playwright");
  await page.keyboard.press("Control+Enter");
  await page.reload();
  // Verify comment saved (need to expose annotation rail or count)
  await expect(page.getByText(/1 annotation/)).toBeVisible();
});
```

**Step 2:** Run, may FAIL until annotation rail is built (M7) — for now, verify via Supabase dashboard that the row exists.

**Step 3 — Commit M6:**
```bash
git add ui/web
git commit -m "feat(ui): highlight + Comment popover + save annotation to Supabase

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M7: Right rail review mode + edit/resolve/delete

### Task 7.1: Annotation rail component

**Files:**
- Create: `ui/web/components/AnnotationRail.tsx`

**Step 1:** Implement:
```typescript
"use client";
import { browserSupabase } from "@/lib/supabase";
import { useState } from "react";

type Annotation = {
  id: string;
  quote: string;
  comment: string;
  author_name: string;
  created_at: string;
  status: string;
};

export function AnnotationRail({
  artifactName,
  annotations,
  onChange,
}: {
  artifactName: string;
  annotations: Annotation[];
  onChange: () => void;
}) {
  const [filter, setFilter] = useState<"open" | "resolved" | "deleted">("open");
  const visible = annotations.filter((a) => a.status === filter);

  async function update(id: string, status: string) {
    await browserSupabase.from("annotations").update({ status }).eq("id", id);
    onChange();
  }

  async function edit(id: string, comment: string) {
    await browserSupabase.from("annotations").update({ comment }).eq("id", id);
    onChange();
  }

  return (
    <aside className="fixed right-0 top-0 bottom-0 w-80 p-6 bg-white border-l border-[#E5E5E0] overflow-y-auto">
      <h3 className="text-xs uppercase tracking-wider text-[#6B6B6B]">
        Annotations on {artifactName} · {visible.length}
      </h3>
      <ul className="mt-6 space-y-6">
        {visible.map((a) => (
          <li key={a.id} className="border-b border-[#E5E5E0] pb-4">
            <p className="font-serif italic text-sm text-[#6B6B6B]">"{a.quote.slice(0, 100)}{a.quote.length > 100 ? "..." : ""}"</p>
            <p className="mt-2 text-sm">{a.comment}</p>
            <p className="mt-2 text-xs text-[#6B6B6B]">{a.author_name} · {new Date(a.created_at).toLocaleDateString()}</p>
            {a.status === "open" && (
              <div className="mt-2 flex gap-3 text-xs">
                <button onClick={() => {
                  const next = prompt("Edit comment", a.comment);
                  if (next) edit(a.id, next);
                }} className="hover:underline">edit</button>
                <button onClick={() => update(a.id, "resolved")} className="hover:underline">resolve</button>
                <button onClick={() => update(a.id, "deleted")} className="hover:underline">delete</button>
              </div>
            )}
          </li>
        ))}
      </ul>
      <div className="mt-12 text-xs flex gap-3">
        {(["open", "resolved", "deleted"] as const).map((f) => (
          <button key={f} onClick={() => setFilter(f)} className={filter === f ? "underline" : "text-[#6B6B6B]"}>
            {f}
          </button>
        ))}
      </div>
    </aside>
  );
}
```

### Task 7.2: Wire rail into reading mode + `A` key toggle

**Files:**
- Modify: `ui/web/components/ArtifactViewer.tsx`

**Step 1:** Add rail toggle state, listen for `A` key, pass annotations through.

```typescript
// Add to ArtifactViewer:
const [railOpen, setRailOpen] = useState(false);

useEffect(() => {
  function onKey(e: KeyboardEvent) {
    if (e.key === "a" && !e.ctrlKey && !e.metaKey && !(e.target as HTMLElement)?.matches("input, textarea")) {
      setRailOpen((p) => !p);
    }
    if (e.key === "Escape") setRailOpen(false);
  }
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}, []);

// Render <AnnotationRail ... /> conditionally on railOpen
```

**Step 2:** Run test from Task 6.5 again. Should now pass.

**Step 3 — Commit M7:**
```bash
git add ui/web
git commit -m "feat(ui): annotation rail with edit/resolve/delete + A toggle

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 4 — Skill backend rewrite

## M8: state.sh rewritten with Supabase backend (feature-flagged)

### Task 8.1: Create Supabase helper module for skill

**Files:**
- Create: `base-agent-setup/scripts/supabase.sh`

**Step 1:** Implement Supabase REST helpers:
```bash
#!/usr/bin/env bash
# base-agent-setup/scripts/supabase.sh
# Lightweight wrappers around Supabase REST API for the skill.

set -euo pipefail

SUPABASE_URL="${SUPABASE_OPERATOR_URL:?must set SUPABASE_OPERATOR_URL}"
SUPABASE_KEY="${SUPABASE_OPERATOR_SERVICE_ROLE_KEY:?must set SUPABASE_OPERATOR_SERVICE_ROLE_KEY}"
SUPABASE_SCHEMA="operator_ui"

_supabase_headers() {
  printf -- "-H apikey:%s -H Authorization:Bearer %s -H Content-Profile:%s -H Accept-Profile:%s -H Prefer:return=representation -H Content-Type:application/json" \
    "$SUPABASE_KEY" "$SUPABASE_KEY" "$SUPABASE_SCHEMA" "$SUPABASE_SCHEMA"
}

supabase_post() {
  local table="$1"; local body="$2"
  curl -sS -X POST "${SUPABASE_URL}/rest/v1/${table}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Profile: ${SUPABASE_SCHEMA}" \
    -H "Accept-Profile: ${SUPABASE_SCHEMA}" \
    -H "Prefer: return=representation" \
    -H "Content-Type: application/json" \
    -d "$body"
}

supabase_get() {
  local query="$1"
  curl -sS "${SUPABASE_URL}/rest/v1/${query}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Accept-Profile: ${SUPABASE_SCHEMA}"
}

supabase_patch() {
  local query="$1"; local body="$2"
  curl -sS -X PATCH "${SUPABASE_URL}/rest/v1/${query}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Profile: ${SUPABASE_SCHEMA}" \
    -H "Accept-Profile: ${SUPABASE_SCHEMA}" \
    -H "Prefer: return=representation" \
    -H "Content-Type: application/json" \
    -d "$body"
}
```

### Task 8.2: Rewrite state.sh — feature-flagged

**Files:**
- Modify: `base-agent-setup/scripts/state.sh`

**Step 1:** Add Supabase backend behind `USE_SUPABASE_BACKEND=1`. Pseudocode:
```bash
# At top of state.sh, after existing init logic:
USE_SUPABASE="${USE_SUPABASE_BACKEND:-0}"

state_init() {
  local slug="$1"
  if [[ "$USE_SUPABASE" == "1" ]]; then
    source "$(dirname "$0")/supabase.sh"
    # Insert customer if not exists
    supabase_post "customers" "{\"slug\":\"${slug}\",\"name\":\"${slug}\"}" || true
    # Get customer_id
    local cid=$(supabase_get "customers?slug=eq.${slug}&select=id" | python -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
    # Create run row
    local started_at=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    local slug_with_ts="${slug}-${started_at}"
    supabase_post "runs" "{\"customer_id\":\"${cid}\",\"slug_with_ts\":\"${slug_with_ts}\",\"started_at\":\"$(date -u +%FT%TZ)\",\"state\":{}}"
    echo "$slug_with_ts"
  else
    # ... existing local file logic ...
    :
  fi
}

state_set() {
  # similar branching ...
}

state_stage_complete() {
  # ...
}

state_get_next_stage() {
  # ...
}

state_resume_from() {
  # ...
}
```

**Step 2:** Test by setting `USE_SUPABASE_BACKEND=1` in shell, running `state_init test-supabase`, verifying row appears in Supabase.

**Step 3 — Commit:**
```bash
git add base-agent-setup/scripts/supabase.sh base-agent-setup/scripts/state.sh
git commit -m "feat(skill): state.sh writes to Supabase when USE_SUPABASE_BACKEND=1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M9: Stage scripts write artifacts to Supabase

### Task 9.1-9.6: One per stage script

For each of `firecrawl-scrape.sh`, `synthesize-brain-doc` flow, `ultravox-create-agent.sh`, `telnyx-claim-did.sh`, `telnyx-wire-texml.sh`, `wire-ultravox-telephony.sh`:

**Step 1:** Identify the existing `cat > runs/$SLUG/{artifact}.{ext}` write site.
**Step 2:** Replace with Supabase POST to `artifacts` table:
```bash
if [[ "${USE_SUPABASE_BACKEND:-0}" == "1" ]]; then
  local content="$(cat ...)"  # build content as before
  local size_bytes=${#content}
  local body=$(python -c "import json,sys;print(json.dumps({'run_id':'$RUN_ID','artifact_name':'brain-doc','content':sys.stdin.read(),'size_bytes':$size_bytes}))" <<< "$content")
  supabase_post "artifacts" "$body"
else
  # legacy file write
  cat > "$RUN_DIR/brain-doc.md" <<EOF
$content
EOF
fi
```

**Step 3:** Test by running `/base-agent` with `USE_SUPABASE_BACKEND=1` against a real customer site; verify all artifact rows appear.

**Step 4:** Commit per stage script (6 commits).

## M10: state_resume_from queries Supabase

### Task 10.1: Implement Supabase-backed resume

**Files:**
- Modify: `base-agent-setup/scripts/state.sh`

**Step 1:** Add to `state_resume_from`:
```bash
state_resume_from() {
  local slug="$1"
  if [[ "${USE_SUPABASE_BACKEND:-0}" == "1" ]]; then
    local cid=$(supabase_get "customers?slug=eq.${slug}&select=id" | python -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
    [[ -z "$cid" ]] && return 1
    local latest=$(supabase_get "runs?customer_id=eq.${cid}&order=started_at.desc&limit=1" | python -c "import sys,json;d=json.load(sys.stdin);print(d[0]['slug_with_ts'] if d else '')")
    [[ -z "$latest" ]] && return 1
    echo "$latest"
  else
    # legacy filesystem walk
    :
  fi
}
```

**Step 2:** Test: resume an in-progress run from Supabase and verify next stage runs correctly.

**Step 3 — Commit + flip the flag:**
```bash
# In .env, change USE_SUPABASE_BACKEND=0 to USE_SUPABASE_BACKEND=1 (local only, not committed)
git add base-agent-setup/scripts/state.sh
git commit -m "feat(skill): state_resume_from queries Supabase under feature flag

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 5 — Protocol-improvement loop

## M11: Generator prompts read lessons table

### Task 11.1: Python helper to fetch lessons

**Files:**
- Create: `base-agent-setup/scripts/fetch_lessons.py`

```python
#!/usr/bin/env python3
"""Fetch active lessons from Supabase and emit them as a markdown block for prompt prepending."""
import os
import sys
import httpx

URL = os.environ["SUPABASE_OPERATOR_URL"]
KEY = os.environ["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"]

r = httpx.get(
    f"{URL}/rest/v1/lessons?promoted_to_prompt=eq.false&order=created_at.desc",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}", "Accept-Profile": "operator_ui"},
)
lessons = r.json()
if not lessons:
    print("(no active lessons)")
    sys.exit(0)

print("# Known protocol-level lessons (apply where relevant)")
print()
for L in lessons:
    print(f"## {L['title']}")
    print(f"**Pattern:** {L['pattern']}")
    print(f"**Fix:** {L['fix']}")
    print()
```

### Task 11.2: Update generator prompts to invoke fetch_lessons.py

**Files:**
- Modify: `base-agent-setup/prompts/synthesize-brain-doc.md`
- Modify: `base-agent-setup/prompts/assemble-rough-system-prompt.md`
- Modify: `base-agent-setup/prompts/generate-discovery-prompt.md`

**Step 1:** Prepend to each:
```
Before generating, run:
```bash
python3 base-agent-setup/scripts/fetch_lessons.py
```
Read the output. Apply any lesson where the pattern is relevant to this artifact.
```

**Step 2 — Commit:**
```bash
git add base-agent-setup/scripts/fetch_lessons.py base-agent-setup/prompts/
git commit -m "feat(prompts): generator prompts read active lessons at run start

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M12: /base-agent refine command

### Task 12.1: Refine flow scaffold

**Files:**
- Create: `base-agent-setup/refine-SKILL.md` (or extend SKILL.md with a refine section)
- Create: `base-agent-setup/scripts/refine.sh`

**Step 1:** Implement the 13-step flow per design doc Section 4. Pseudocode:
```bash
#!/usr/bin/env bash
# base-agent-setup/scripts/refine.sh [slug]

set -euo pipefail
source "$(dirname "$0")/supabase.sh"

SLUG="$1"

# Step 1: latest run
RUN_ID=$(supabase_get "customers?slug=eq.$SLUG&select=id,runs(id,started_at)" | python3 -c "
import sys, json
d = json.load(sys.stdin)[0]
runs = sorted(d['runs'], key=lambda r: r['started_at'], reverse=True)
print(runs[0]['id'])
")

# Step 2: open annotations
ANNOTATIONS=$(supabase_get "annotations?run_id=eq.$RUN_ID&status=eq.open")

# Step 3: lessons context
LESSONS=$(supabase_get "lessons")

# Step 4: classify each annotation interactively (delegate to Claude — output structured JSON)
# This is a Claude Code inline call; the operator approves Y/n per block

# Step 5-9: apply per-run patches → POST new run + new artifacts
# Step 10: append feedback rows
# Step 11: mark consumed annotations resolved
# Step 12: if system-prompt modified, prompt push to live Ultravox
# Step 13: end-of-refine elevation probing
```

(Full implementation requires Claude Code inline classification calls — this scaffold establishes the skeleton; the operator runs it interactively.)

**Step 2:** Test against fixture annotations (see Task 12.2).

### Task 12.2: Refine integration test

**Files:**
- Create: `base-agent-setup/scripts/tests/test_refine.py`

**Step 1:** Pre-populate Supabase with a fixture run + 2 annotations (one factual, one behavioral). Run refine. Assert:
- New run row created with `refined_from_run_id` pointing to fixture
- Original annotations have status=resolved + correct `resolved_classification`
- One feedback row appended for the behavioral annotation

**Step 2 — Commit:**
```bash
git add base-agent-setup/scripts/refine.sh base-agent-setup/scripts/tests/
git commit -m "feat(skill): /base-agent refine flow with classification + lessons probe

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M13: scripts/regenerate-agent.sh — safe Ultravox PATCH

### Task 13.1: HIGHEST-VALUE TEST first

**Files:**
- Create: `base-agent-setup/scripts/tests/test_regenerate_agent.py`

**Step 1:** Write failing test that captures the PATCH behavior:
```python
# base-agent-setup/scripts/tests/test_regenerate_agent.py
import os
import subprocess
from unittest.mock import patch
import respx
import httpx

def test_regenerate_agent_includes_all_fields_in_patch(tmp_path, monkeypatch):
    monkeypatch.setenv("ULTRAVOX_API_KEY", "test-key")
    monkeypatch.setenv("SUPABASE_OPERATOR_URL", "https://fake.supabase.co")
    monkeypatch.setenv("SUPABASE_OPERATOR_SERVICE_ROLE_KEY", "fake-key")

    fake_agent = {
        "agentId": "agent-123",
        "name": "Test Agent",
        "voice": "alex",
        "temperature": 0.7,
        "inactivityMessages": [{"duration": "8s", "message": "Still there?"}],
        "firstSpeaker": "FIRST_SPEAKER_AGENT",
        "model": "fixie-ai/ultravox",
        "selectedTools": [],
        "systemPrompt": "old prompt",
    }

    with respx.mock(base_url="https://api.ultravox.ai") as m:
        m.get("/api/agents/agent-123").mock(return_value=httpx.Response(200, json=fake_agent))
        patch_route = m.patch("/api/agents/agent-123").mock(return_value=httpx.Response(200, json={**fake_agent, "systemPrompt": "new prompt"}))
        # ... mock Supabase calls for state read/write ...
        m.get("https://fake.supabase.co/rest/v1/runs", path__startswith="").mock(return_value=httpx.Response(200, json=[{"id": "run-id", "state": {"ultravox_agent_id": "agent-123"}}]))
        m.get("https://fake.supabase.co/rest/v1/artifacts", path__startswith="").mock(return_value=httpx.Response(200, json=[{"content": "new prompt"}]))

        subprocess.run(["bash", "base-agent-setup/scripts/regenerate-agent.sh", "test-customer"], check=True, env={**os.environ})

        assert patch_route.called
        body = patch_route.calls[0].request.content.decode()
        # Every original field must be in the PATCH body
        for field in ["voice", "temperature", "inactivityMessages", "firstSpeaker", "model", "selectedTools"]:
            assert field in body, f"PATCH body missing {field} — would silently revert to default"
        assert '"systemPrompt": "new prompt"' in body
```

**Step 2:** Run, expect FAIL (script doesn't exist yet).

### Task 13.2: Implement regenerate-agent.sh

**Files:**
- Create: `base-agent-setup/scripts/regenerate-agent.sh`

```bash
#!/usr/bin/env bash
# base-agent-setup/scripts/regenerate-agent.sh [slug]
# Safe Ultravox agent update — fetch ALL settings, then PATCH with full body.

set -euo pipefail
source "$(dirname "$0")/supabase.sh"

SLUG="$1"
ULTRAVOX_KEY="${ULTRAVOX_API_KEY:?must set}"

# 1. Read state
RUN_DATA=$(supabase_get "customers?slug=eq.$SLUG&select=id,runs(id,state)" | python3 -c "
import sys, json
d = json.load(sys.stdin)[0]
runs = sorted(d['runs'], key=lambda r: r.get('started_at', ''), reverse=True)
print(json.dumps({'run_id': runs[0]['id'], 'state': runs[0]['state']}))
")
RUN_ID=$(echo "$RUN_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['run_id'])")
AGENT_ID=$(echo "$RUN_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['state']['ultravox_agent_id'])")

# 2. Fetch ALL live settings
LIVE=$(curl -sS "https://api.ultravox.ai/api/agents/$AGENT_ID" -H "X-API-Key: $ULTRAVOX_KEY")

# Save snapshot for audit
SNAPSHOT_BODY=$(python3 -c "
import sys, json
state_update = {'live_agent_pre_update': json.loads(sys.stdin.read())}
print(json.dumps({'state': state_update}))
" <<< "$LIVE")

# 3. Read latest system-prompt artifact
NEW_PROMPT=$(supabase_get "artifacts?run_id=eq.$RUN_ID&artifact_name=eq.system-prompt&select=content" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['content'])")

# 4. Construct PATCH body — every field from LIVE preserved, systemPrompt swapped
PATCH_BODY=$(python3 -c "
import sys, json
live = json.loads(sys.stdin.read())
live['systemPrompt'] = '''$(echo "$NEW_PROMPT" | python3 -c 'import sys;print(sys.stdin.read().replace(chr(39),chr(92)+chr(39)))')'''
# Strip read-only fields
for k in ['agentId', 'created', 'updated']:
    live.pop(k, None)
print(json.dumps(live))
" <<< "$LIVE")

# 5. PATCH
RESULT=$(curl -sS -X PATCH "https://api.ultravox.ai/api/agents/$AGENT_ID" \
  -H "X-API-Key: $ULTRAVOX_KEY" \
  -H "Content-Type: application/json" \
  -d "$PATCH_BODY")

# 6. Verify nothing else changed
python3 -c "
import sys, json
live = json.loads('''$LIVE''')
result = json.loads(sys.stdin.read())
for k in ['voice', 'temperature', 'firstSpeaker', 'model', 'selectedTools']:
    assert live.get(k) == result.get(k), f'Drift detected on {k}: {live.get(k)} -> {result.get(k)}'
print('PATCH safe: only systemPrompt changed')
" <<< "$RESULT"

# 7. Update state
supabase_patch "runs?id=eq.$RUN_ID" "{\"state\":{\"system_prompt_pushed_at\":\"$(date -u +%FT%TZ)\"}}"
echo "✓ Agent $AGENT_ID system prompt updated"
```

**Step 3:** Run test, expect PASS:
```bash
cd base-agent-setup && python -m pytest scripts/tests/test_regenerate_agent.py -v
```

**Step 4 — Commit:**
```bash
git add base-agent-setup/scripts/regenerate-agent.sh base-agent-setup/scripts/tests/test_regenerate_agent.py
git commit -m "feat(skill): regenerate-agent.sh — safe Ultravox full-PATCH preserving all fields

Replaces the previous POST-new+DELETE-old pattern. Fetches all live settings
first, builds a PATCH body containing every field, then PATCHes — preventing
the silent-default-revert footgun. Test verifies every field round-trips.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 13.3: Update CLAUDE.md with corrected rule

**Files:**
- Modify: `CLAUDE.md`

**Step 1:** Replace `Never PATCH Ultravox agents` rule with:
```markdown
### Updating a live Ultravox agent

**Always include ALL settings in the PATCH body.** Ultravox PATCH semantics revert any field not explicitly included to the API default — silently wipes voice/temp/inactivity/tools. The safe procedure: GET the agent first, copy every field forward, modify only the field you intend to change, then PATCH with the complete body.

The script `scripts/regenerate-agent.sh [slug]` does this safely. Invoke it for any live-agent change. Never construct a partial PATCH body — always carry every field forward.

The previous `POST-new + DELETE-old` rule is replaced by this — agent id is preserved, no telephony re-wire needed.
```

**Step 2 — Commit:**
```bash
git add CLAUDE.md
git commit -m "docs(claude.md): correct Ultravox update rule — full-PATCH not POST/DELETE

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M14: /base-agent review-feedback command

### Task 14.1: Review-feedback flow scaffold

**Files:**
- Create: `base-agent-setup/scripts/review-feedback.sh`

**Step 1:** Implement Phase 1 (feedback → lessons clustering + P/K/D actions) + Phase 2 (lessons → prompts) per design doc Section 5.

(Full implementation involves Claude Code inline reasoning for clustering — operator-driven via interactive prompts.)

**Step 2 — Commit:**
```bash
git add base-agent-setup/scripts/review-feedback.sh
git commit -m "feat(skill): /base-agent review-feedback — methodology review with P/K/D

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 6 — Verification

## M15: verify.py module

### Task 15.1: Test fixture + failing test

**Files:**
- Create: `ui/server/tests/test_verify.py`

**Step 1:** Mock all 4 vendor APIs, write failing test:
```python
import respx
import httpx
from server.verify import run_verification

@respx.mock
def test_verify_writes_complete_report(tmp_path):
    # Mock Ultravox
    respx.get("https://api.ultravox.ai/api/agents/agent-123").mock(
        return_value=httpx.Response(200, json={"agentId": "agent-123", "name": "Test", "voice": "alex", "temperature": 0.7, "systemPrompt": "x" * 600, "selectedTools": []})
    )
    # Mock Telnyx, Supabase, n8n... (similar)
    
    state = {"ultravox_agent_id": "agent-123", "telnyx_did": "+61...", ...}
    report = run_verification(state)
    assert report["summary"]["pass"] >= 7
    assert "checks" in report
    for check_id in ["ultravox_agent_exists", "telnyx_did_active", "supabase_workspace_exists"]:
        assert any(c["id"] == check_id for c in report["checks"])
```

### Task 15.2: Implement verify.py

**Files:**
- Create: `ui/server/verify.py`

**Step 1:** Implement 10 checks per design doc Section 6:
```python
import os
import time
import httpx

CHECKS = []

def check(id):
    def deco(fn):
        CHECKS.append((id, fn))
        return fn
    return deco

@check("ultravox_agent_exists")
def _ultravox_agent_exists(state):
    agent_id = state["ultravox_agent_id"]
    r = httpx.get(f"https://api.ultravox.ai/api/agents/{agent_id}", headers={"X-API-Key": os.environ["ULTRAVOX_API_KEY"]})
    if r.status_code != 200:
        return {"status": "fail", "detail": f"GET returned {r.status_code}", "remediation": "agent may have been deleted; re-run /base-agent stage 6"}
    return {"status": "pass", "detail": f"name={r.json()['name']}"}

# ... 9 more checks ...

def run_verification(state, include_call=False):
    results = []
    for cid, fn in CHECKS:
        t0 = time.time()
        try:
            r = fn(state)
            r["id"] = cid
            r["ms"] = int((time.time() - t0) * 1000)
        except Exception as e:
            r = {"id": cid, "status": "fail", "ms": int((time.time() - t0) * 1000), "detail": f"exception: {e}"}
        results.append(r)
    if include_call:
        results.append(_test_call(state))
    summary = {"pass": sum(1 for c in results if c["status"] == "pass"), "fail": sum(1 for c in results if c["status"] == "fail"), "skip": sum(1 for c in results if c["status"] == "skip")}
    return {"verified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "summary": summary, "checks": results}
```

**Step 2:** Run test, expect PASS.

**Step 3 — Commit:**
```bash
git add ui/server/verify.py ui/server/tests/test_verify.py
git commit -m "feat(verify): Python verify module with 10 deterministic checks

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M16: /base-agent verify command + Stage 11.5 hook

### Task 16.1: CLI command

**Files:**
- Create: `ui/server/__main__.py`

```python
# ui/server/__main__.py
import argparse, json, os
from server.verify import run_verification
import httpx

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--slug", required=True)
    p.add_argument("--include-call", action="store_true")
    args = p.parse_args()

    # Fetch state from Supabase
    URL = os.environ["SUPABASE_OPERATOR_URL"]
    KEY = os.environ["SUPABASE_OPERATOR_SERVICE_ROLE_KEY"]
    r = httpx.get(f"{URL}/rest/v1/customers?slug=eq.{args.slug}&select=id,runs(id,state,started_at)",
                  headers={"apikey": KEY, "Authorization": f"Bearer {KEY}", "Accept-Profile": "operator_ui"})
    customer = r.json()[0]
    runs = sorted(customer["runs"], key=lambda x: x["started_at"], reverse=True)
    run = runs[0]
    state = run["state"]

    report = run_verification(state, include_call=args.include_call)

    # Write to verifications table
    httpx.post(f"{URL}/rest/v1/verifications",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}", "Content-Profile": "operator_ui", "Content-Type": "application/json"},
        json={"run_id": run["id"], "verified_at": report["verified_at"], "summary": report["summary"], "checks": report["checks"]})

    print(json.dumps(report, indent=2))
    print(f"\n{report['summary']['pass']} pass, {report['summary']['fail']} fail, {report['summary']['skip']} skip")

if __name__ == "__main__":
    main()
```

### Task 16.2: Stage 11.5 advisory hook

**Files:**
- Modify: `base-agent-setup/SKILL.md`

**Step 1:** After Stage 11 in SKILL.md, add:
```markdown
### Stage 11.5 — Auto-verify (advisory)

After Stage 11 completes, run verify advisory check:

```bash
python -m server.verify --slug "$SLUG" || true
```

The trailing `|| true` makes this advisory — verify failures don't halt the onboarding. The final summary block should include verification pass/fail counts.
```

**Step 2 — Commit:**
```bash
git add ui/server/__main__.py base-agent-setup/SKILL.md
git commit -m "feat(verify): /base-agent verify CLI + Stage 11.5 advisory hook

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

## M17: --include-call flag

### Task 17.1: Implement test-call check

**Files:**
- Modify: `ui/server/verify.py`

**Step 1:** Implement `_test_call(state)`:
```python
def _test_call(state):
    """Place a Telnyx programmatic call to the customer's DID, wait for answer, hang up."""
    import time
    did = state["telnyx_did"]
    api_key = os.environ["TELNYX_API_KEY"]
    r = httpx.post(
        "https://api.telnyx.com/v2/calls",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json={"to": did, "from": os.environ["TELNYX_FROM_NUMBER"], "connection_id": os.environ["TELNYX_CONNECTION_ID"]},
    )
    if r.status_code not in (200, 201):
        return {"id": "test_call", "status": "fail", "detail": f"call create failed: {r.status_code}"}
    call_id = r.json()["data"]["call_control_id"]
    # Wait briefly for answer event
    time.sleep(8)
    # Hang up
    httpx.post(f"https://api.telnyx.com/v2/calls/{call_id}/actions/hangup", headers={"Authorization": f"Bearer {api_key}"})
    return {"id": "test_call", "status": "pass", "detail": "call placed and hung up"}
```

**Step 2:** Add test for `--include-call` flag.

**Step 3 — Commit:**
```bash
git add ui/server/verify.py ui/server/tests/test_verify.py
git commit -m "feat(verify): --include-call flag triggers Telnyx programmatic test call

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# Phase 7 — UI polish

## M18: Run history switcher

### Task 18.1: Component + URL routing

**Files:**
- Create: `ui/web/components/RunHistory.tsx`
- Create: `ui/web/app/c/[slug]/run/[runId]/page.tsx`

**Step 1:** Implement dropdown that lists all runs for a customer; switching changes URL.

**Step 2:** Test + commit.

## M19: Command palette (Ctrl+K)

### Task 19.1: Palette component

**Files:**
- Create: `ui/web/components/CommandPalette.tsx`

**Step 1:** Implement modal triggered by Ctrl+K. Fuzzy-search customers, artifacts, actions.

**Step 2:** Test + commit.

## M20: Inspect view stub

### Task 20.1: Inspect page

**Files:**
- Create: `ui/web/app/c/[slug]/inspect/page.tsx`

**Step 1:** Read latest verification row, render as syntax-highlighted JSON. If absent, show "Not yet verified" + copy-command button.

**Step 2:** Test + commit.

---

# Phase 8 — Docs + handoff

## M21: README + INSTALL + CLAUDE.md final updates

### Task 21.1: README rewrite

**Files:**
- Modify: `README.md`

**Step 1:** Add cloud model description, Vercel URL, password share instructions (link to private channel), updated install steps.

### Task 21.2: INSTALL.md rewrite

**Files:**
- Modify: `INSTALL.md`

**Step 1:** Path A becomes "Use the shared Supabase project + Vercel URL" — share URL + password via private channel; clone repo for the local skill side; set env vars.

### Task 21.3: Final friend-onboarding test

**Step 1:** Manually verify a clean clone:
```bash
cd /tmp
git clone https://github.com/Spotfunnel/ZeroOnboarding.git
cd ZeroOnboarding
# Follow INSTALL.md
```
Time the process. Should be < 10 minutes. If longer, fix the docs.

**Step 2 — Final commit:**
```bash
git add README.md INSTALL.md
git commit -m "docs: update README + INSTALL for cloud model + Vercel URL

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# End-to-end verification

After all 21 milestones, run the 12-step verification from the design doc (`docs/plans/2026-04-26-operator-ui-design.md`, "Verification" section). If steps 1-12 work, v1 is shipped.

---

# Estimated effort

- Phase 0: ~1 hour
- Phase 1: 1 day (M1, M2)
- Phase 2: 1-2 days (M3, M4, M5)
- Phase 3: 2-3 days (M6, M7)
- Phase 4: 2-3 days (M8, M9, M10) ← biggest unknown
- Phase 5: 2-3 days (M11, M12, M13, M14)
- Phase 6: 1 day (M15, M16, M17)
- Phase 7: 1-2 days (M18, M19, M20)
- Phase 8: 0.5 day (M21)

**Total: ~10-15 days of focused work.**

---

# Skills referenced

- `superpowers:executing-plans` — to drive task-by-task execution
- `superpowers:tdd` — TDD discipline already integrated above
- Skills NOT to invoke: `superpowers:frontend-design` (already covered in design doc), `superpowers:mcp-builder` (out of scope)
