import { test, expect } from "./fixtures";

// M18 — Run history switcher.
//
// The fixture customer test-roster persists across tests, so we own a SECOND
// run row's lifetime ourselves. Inserted via service-role-less REST (the
// anon key has SELECT on runs but not INSERT, so we use the public REST
// endpoint with an env-supplied service role; if SUPABASE_SERVICE_ROLE_KEY
// isn't set we skip the dropdown-with-2-entries test and fall back to
// asserting the dropdown renders the existing single run.

const SUPABASE_URL = "https://ldpvfolmloexlmeoqkxo.supabase.co";
const SUPABASE_ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkcHZmb2xtbG9leGxtZW9xa3hvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2ODM3NjIsImV4cCI6MjA5MjI1OTc2Mn0.UGbup57Kcv0r5eoQB1elju7DEk_moQJQZnSHkfuGRKE";
const SERVICE_ROLE = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

async function getTestRosterCustomerId(): Promise<string | null> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/customers?slug=eq.test-roster&select=id`,
    {
      headers: {
        apikey: SUPABASE_ANON,
        Authorization: `Bearer ${SUPABASE_ANON}`,
        "Accept-Profile": "operator_ui",
      },
    },
  );
  const rows = (await res.json()) as Array<{ id: string }>;
  return rows[0]?.id ?? null;
}

async function insertSecondRun(customerId: string): Promise<string | null> {
  if (!SERVICE_ROLE) return null;
  const body = {
    customer_id: customerId,
    started_at: new Date(Date.now() - 1000 * 60 * 60 * 24 * 3).toISOString(),
    state: { customer_name: "Roster Test", note: "playwright second run" },
    stage_complete: 5,
  };
  const res = await fetch(`${SUPABASE_URL}/rest/v1/runs`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Profile": "operator_ui",
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) return null;
  const rows = (await res.json()) as Array<{ id: string }>;
  return rows[0]?.id ?? null;
}

async function deleteRun(runId: string): Promise<void> {
  if (!SERVICE_ROLE) return;
  await fetch(`${SUPABASE_URL}/rest/v1/runs?id=eq.${runId}`, {
    method: "DELETE",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Profile": "operator_ui",
      Prefer: "return=minimal",
    },
  });
}

test.describe("M18 run history", () => {
  let customerId: string | null = null;
  let secondRunId: string | null = null;

  test.beforeAll(async () => {
    customerId = await getTestRosterCustomerId();
    if (customerId) {
      secondRunId = await insertSecondRun(customerId);
    }
  });

  test.afterAll(async () => {
    if (secondRunId) await deleteRun(secondRunId);
  });

  test("dropdown opens, lists runs, navigates to run-scoped page", async ({ page }) => {
    test.skip(!secondRunId, "needs SUPABASE_SERVICE_ROLE_KEY env var to seed second run");

    await page.goto("/c/test-roster");

    const toggle = page.getByTestId("run-history-toggle");
    await expect(toggle).toBeVisible();
    await toggle.click();

    const list = page.getByTestId("run-history-list");
    await expect(list).toBeVisible();

    const items = list.getByTestId("run-history-item");
    expect(await items.count()).toBeGreaterThanOrEqual(2);

    // Click the second row (older run) — it links to /c/test-roster/run/{runId}.
    const second = items.nth(1);
    await second.click();

    await expect(page).toHaveURL(new RegExp(`/c/test-roster/run/${secondRunId}$`));
    await expect(page.getByTestId("run-scope-banner")).toBeVisible();
    await expect(page.getByText(/Historical run/)).toBeVisible();
  });

  test("dropdown renders even with one run", async ({ page }) => {
    await page.goto("/c/test-roster");
    const toggle = page.getByTestId("run-history-toggle");
    await expect(toggle).toBeVisible();
    await toggle.click();
    const list = page.getByTestId("run-history-list");
    await expect(list).toBeVisible();
    expect(await list.getByTestId("run-history-item").count()).toBeGreaterThanOrEqual(1);
  });
});
