# n8n Error Wiring

All n8n workflows on `spotfunnel.app.n8n.cloud` are wired to a central error reporter that forwards failures to the SpotFunnel dashboard (`workflow_errors` table), where they surface on `/admin/health`.

**Date wired:** 2026-04-19
**Wired by:** automation script (`.tmp-sync/wire-n8n-errors.js`)

## Architecture

```
┌─────────────────────────────────────────────┐
│  Any active n8n workflow fails              │
│  (settings.errorWorkflow = 8UJUhRw26ZtVH9HV)│
└─────────────────┬───────────────────────────┘
                  │
                  ▼
        ┌────────────────────────────┐
        │ Global Error Alert System  │  n8n workflow 8UJUhRw26ZtVH9HV
        │                            │
        │ [Error Trigger]            │
        │         │                  │
        │    ┌────┴────┐             │
        │    ▼         ▼             │
        │  Gmail    HTTP POST        │
        │  (leo+   →  dashboard-     │
        │   kye)     server          │
        └─────────────┬──────────────┘
                      │ x-n8n-token header
                      ▼
   https://dashboard-server-production-0ee1.up.railway.app/webhooks/n8n-error
                      │
                      ▼
         Supabase `workflow_errors` table
                      │
                      ▼
              /admin/health page
```

Parallel fan-out: each failure emails the founders **and** logs to Supabase — existing Gmail alert path was preserved untouched.

## Reporter workflow

| Field | Value |
| --- | --- |
| Name | Global Error Alert System |
| ID | `8UJUhRw26ZtVH9HV` |
| n8n URL | https://spotfunnel.app.n8n.cloud/workflow/8UJUhRw26ZtVH9HV |
| Active | yes |
| Nodes | `Error Trigger` → [`Send Error Alert to Founders` (Gmail), `Dashboard Error Log` (HTTP POST)] |

The new `Dashboard Error Log` node posts:

- **URL:** `https://dashboard-server-production-0ee1.up.railway.app/webhooks/n8n-error`
- **Header:** `x-n8n-token: XyfSNdfcUwbh8FMDlxDFqrDSt6rXJMcP` (hardcoded value; matches Railway env `N8N_ERROR_WEBHOOK_TOKEN` on `dashboard-server`)
- **Body (JSON, built via expression):**
  ```json
  {
    "source": "n8n",
    "severity": "error",
    "message": "n8n workflow \"<name>\" failed: <error message>",
    "workflow": { "id": "...", "name": "..." },
    "execution": { "id": "...", "error": { "message": "...", "node": { "name": "..." }, "stack": "..." } },
    "payload": <full $json>
  }
  ```
- **neverError: true** so a dashboard outage never kills the n8n error-reporter itself.

### Heads-up on the webhook URL

The brief specifies `https://api.gospotfunnel.com.au/webhooks/n8n-error`, but as of 2026-04-19 that hostname is **NXDOMAIN** (no A record configured on Railway). The reporter currently points at the working Railway public URL.

**Action for Leo:** add a custom-domain entry on the Railway `dashboard-server` service for `api.gospotfunnel.com.au`, then either:

- update the Dashboard Error Log node URL in n8n to the vanity domain, OR
- leave the Railway URL — it's stable as long as the service isn't recreated.

## Wiring results

| Bucket | Count |
| --- | --- |
| Total workflows in n8n instance | 45 |
| Wired to reporter (pre-run) | 8 |
| Wired to reporter (post-run) | **23** |
| Newly wired this run | 15 (12 in first pass + 3 in re-run after schema fixes) |
| Archived (skipped) | 21 |
| Points to a different error workflow | 0 |
| Failed | 0 |
| Reporter itself (skipped) | 1 |

### All 23 wired workflows

Every non-archived workflow on the instance is now reporting.

| Active | Name | ID |
| --- | --- | --- |
| yes | Blueprint/Solar/Check Availability FINAL | Tf9HQ_2P2NPUIF1mwnqCU |
| yes | Postcode Check NSW | _dO-5AOO8OBLH_cW6O2yB |
| yes | Qoute Form Pipecat Demo | 2orN5sJgHqegvxoB |
| yes | Spot Funnel - OAuth v2 Complete | s7vBjKcFf_7vVK55A74uM |
| yes | SpotFunnel Demo - Book Consultation | 5FPrWO8inVbPFq4b |
| yes | SpotFunnel Demo - Check Availability | 3RVJ2srHwd2UEo7g |
| yes | SpotFunnel Demo - Confirmation SMS | 0tXUCPaJPVoC8jkL |
| yes | Spotfunnel Lead Post-Processing (Gmail Route) | 6JNA8JvEoY5YJP3A |
| yes | SpotFunnel v2 - Lead Notification | yxNb0odKgWsXtLpe |
| yes | Supabase GMT+10 | HaO8EBL6TSof0wbG |
| yes | Telco Works — Send Call Email (Gmail) | IeJ0OCst5dNavzRY |
| yes | Teleca - Send Email | AW7EbO5iDbimymN3 |
| yes | Teleca Send SMS | hJfyjLJeeqM3rhMo |
| yes | Vapi Axford Solar Onboarding | UsimyxldcjhJ-uekxIC8Y |
| no  | Blueprint/solar/book-appointment WORKING | 9QNYWum3tb0HPxp6lwVEL |
| no  | On Guard Steve — Call Summary Email | mKmwC1MEg30TiWOm |
| no  | On Guard Steve — Emergency SMS | gTtlVgI86pS6sAZE |
| no  | On Guard Steve — Onboarding Email | l1oE1kanZRP6gTwB |
| no  | Send Confirmation SMS | qmCDpQfEYhOl_iWT4cNDe |
| no  | Send SMS | Xl_Xb---lXgYY1i5Mwwku |
| no  | Solar AI Backend Blue Print | 5f9uNbYUE7TEMinYmdOHj |
| no  | Spot Funnel - V3 Final Production | 44pSWwFgjGXG6YTkDFjuB |
| no  | SpotFunnel Lead Enrichment | lTbZDZnTnBkvifmIMDezL |

Inactive workflows are also wired — if Leo reactivates one later, error reporting works immediately without another round-trip.

### 21 archived workflows (intentionally skipped)

n8n's public API returns `400 "Cannot update an archived workflow."` on PUT. These don't run so they cannot fail; safe to ignore.

## Environment variables

### On the n8n Cloud instance
**None required.** The dashboard token is hardcoded inside the Dashboard Error Log node (n8n Cloud does not expose `$env.*` for tenants). If you rotate the token, update it in two places:

1. Railway `dashboard-server` env var `N8N_ERROR_WEBHOOK_TOKEN`
2. The `x-n8n-token` header in the reporter's Dashboard Error Log HTTP node (https://spotfunnel.app.n8n.cloud/workflow/8UJUhRw26ZtVH9HV)

### On Railway `dashboard-server`

Already set:
- `N8N_ERROR_WEBHOOK_TOKEN = XyfSNdfcUwbh8FMDlxDFqrDSt6rXJMcP`

## How to test end-to-end

### Option A: Re-run the smoke test

```bash
curl -X POST https://dashboard-server-production-0ee1.up.railway.app/webhooks/n8n-error \
  -H "content-type: application/json" \
  -H "x-n8n-token: XyfSNdfcUwbh8FMDlxDFqrDSt6rXJMcP" \
  -d '{
    "source": "n8n",
    "workflow": { "id": "smoke", "name": "Smoke Test" },
    "execution": { "id": "smoke-exec-1", "error": { "message": "synthetic smoke test" } }
  }'
```

Expect `{"ok":true}`. Then check Supabase:

```sql
select id, message, created_at
from workflow_errors
where source = 'n8n'
order by created_at desc
limit 5;
```

(Already verified 2026-04-19 01:01 UTC — row `e5f27805-752e-4c4a-ba1f-47612f4557b1` is in the table from Claude's smoke test.)

### Option B: Force a real n8n workflow to fail

1. In n8n, open any wired active workflow (e.g. `Teleca Send SMS`).
2. Execute it manually with invalid input (e.g. trigger the webhook with a missing required field).
3. n8n fires its error path → reporter → Gmail alert + `POST /webhooks/n8n-error`.
4. Check `/admin/health` on the dashboard — the error appears in the Workflow Errors panel.
5. The founder Gmail (`leo@getspotfunnel.com`, `leo.gewert@gmail.com`, `kyewalker@icloud.com`) also receives an email.

### Option C: Check admin/health

Log into `/admin/health` — the "Workflow errors" section lists recent failures. The smoke-test entry should currently be visible.

## Reuse / future customers

When onboarding a new customer with their own n8n workflows, ensure each new workflow has `settings.errorWorkflow = 8UJUhRw26ZtVH9HV` set in its workflow settings (three-dot menu → Settings → Error Workflow → Global Error Alert System). Alternatively re-run `.tmp-sync/wire-n8n-errors.js` — it's idempotent.

## Known limitation: no workspace attribution

The dashboard's `workflow_errors.workspace_id` is currently set to `NULL` for all n8n errors — the webhook receiver has no way to map an n8n workflow ID to a SpotFunnel workspace. If/when per-tenant error filtering is needed, one option is to set a tag on each n8n workflow (e.g. `workspace:teleca`) and teach the receiver to parse that from the payload.
