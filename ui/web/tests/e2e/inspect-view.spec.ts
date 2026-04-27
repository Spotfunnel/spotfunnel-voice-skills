import { test, expect } from "./fixtures";

// M20 — Inspect view stub.
//
// Empty state always asserted. Seeded-row state requires SUPABASE_SERVICE_ROLE_KEY
// because anon role can't INSERT into verifications.

const SUPABASE_URL = "https://ldpvfolmloexlmeoqkxo.supabase.co";
const SUPABASE_ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkcHZmb2xtbG9leGxtZW9xa3hvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2ODM3NjIsImV4cCI6MjA5MjI1OTc2Mn0.UGbup57Kcv0r5eoQB1elju7DEk_moQJQZnSHkfuGRKE";
const SERVICE_ROLE = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

async function getLatestRunId(slug: string): Promise<string | null> {
  const cust = await fetch(
    `${SUPABASE_URL}/rest/v1/customers?slug=eq.${slug}&select=id`,
    {
      headers: {
        apikey: SUPABASE_ANON,
        Authorization: `Bearer ${SUPABASE_ANON}`,
        "Accept-Profile": "operator_ui",
      },
    },
  );
  const cRows = (await cust.json()) as Array<{ id: string }>;
  if (cRows.length === 0) return null;
  const customerId = cRows[0].id;
  const runRes = await fetch(
    `${SUPABASE_URL}/rest/v1/runs?customer_id=eq.${customerId}&select=id&order=started_at.desc&limit=1`,
    {
      headers: {
        apikey: SUPABASE_ANON,
        Authorization: `Bearer ${SUPABASE_ANON}`,
        "Accept-Profile": "operator_ui",
      },
    },
  );
  const rRows = (await runRes.json()) as Array<{ id: string }>;
  return rRows[0]?.id ?? null;
}

async function deleteVerificationsForRun(runId: string): Promise<void> {
  if (!SERVICE_ROLE) return;
  await fetch(
    `${SUPABASE_URL}/rest/v1/verifications?run_id=eq.${runId}`,
    {
      method: "DELETE",
      headers: {
        apikey: SERVICE_ROLE,
        Authorization: `Bearer ${SERVICE_ROLE}`,
        "Content-Profile": "operator_ui",
        Prefer: "return=minimal",
      },
    },
  );
}

async function insertVerification(
  runId: string,
  summary: { pass: number; fail: number; skip: number },
): Promise<string | null> {
  if (!SERVICE_ROLE) return null;
  const body = {
    run_id: runId,
    verified_at: new Date().toISOString(),
    summary,
    checks: [
      { name: "telnyx_did_active", status: "pass" },
      { name: "ultravox_agent_reachable", status: "pass" },
    ],
  };
  const res = await fetch(`${SUPABASE_URL}/rest/v1/verifications`, {
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

test.describe("M20 Inspect view", () => {
  test("empty state when no verification row exists", async ({ page }) => {
    // Make sure no row exists for the latest run.
    const runId = await getLatestRunId("test-roster");
    if (runId && SERVICE_ROLE) await deleteVerificationsForRun(runId);

    await page.goto("/c/test-roster/inspect");
    await expect(page.getByTestId("inspect-empty")).toBeVisible();
    await expect(
      page.getByText(/Run \/base-agent verify test-roster/),
    ).toBeVisible();
  });

  test("renders JSON when a verification row is seeded", async ({ page }) => {
    test.skip(!SERVICE_ROLE, "needs SUPABASE_SERVICE_ROLE_KEY env var");

    const runId = await getLatestRunId("test-roster");
    expect(runId).not.toBeNull();
    if (!runId) return;

    await deleteVerificationsForRun(runId);
    const inserted = await insertVerification(runId, { pass: 2, fail: 0, skip: 0 });
    expect(inserted).not.toBeNull();

    try {
      await page.goto("/c/test-roster/inspect");
      const json = page.getByTestId("inspect-json");
      await expect(json).toBeVisible();
      await expect(json).toContainText("telnyx_did_active");
      // Status dot reflects all-pass → green hex.
      const dot = page.getByTestId("inspect-page-dot");
      await expect(dot).toHaveAttribute("style", /3CB371/i);
    } finally {
      await deleteVerificationsForRun(runId);
    }
  });

  test("customer page shows green dot when verification all-pass", async ({ page }) => {
    test.skip(!SERVICE_ROLE, "needs SUPABASE_SERVICE_ROLE_KEY env var");

    const runId = await getLatestRunId("test-roster");
    if (!runId) return;
    await deleteVerificationsForRun(runId);
    const inserted = await insertVerification(runId, { pass: 2, fail: 0, skip: 0 });
    expect(inserted).not.toBeNull();

    try {
      await page.goto("/c/test-roster");
      const link = page.getByTestId("inspect-deployment-link");
      await expect(link).toBeVisible();
      await expect(link).toHaveAttribute("data-dot-color", "green");
    } finally {
      await deleteVerificationsForRun(runId);
    }
  });

  test("customer page shows gray dot when no verification row", async ({ page }) => {
    const runId = await getLatestRunId("test-roster");
    if (runId && SERVICE_ROLE) await deleteVerificationsForRun(runId);

    await page.goto("/c/test-roster");
    const link = page.getByTestId("inspect-deployment-link");
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute("data-dot-color", "gray");
  });
});
