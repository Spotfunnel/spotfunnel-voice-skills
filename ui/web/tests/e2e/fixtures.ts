// Shared Playwright fixture for the operator UI e2e suite.
//
// Bypasses the OperatorNameGate (M6) by seeding `localStorage.operatorName`
// in every browser context before the page loads. Without this, the gate
// intercepts every page load post-hydration and replaces the body, breaking
// all assertions that target real page content.
//
// Also cleans up any annotation rows authored by "playwright" before each
// test so a flaky/aborted prior run can't leak <mark> overlays that change
// selection geometry on the subsequent test.
//
// Specs should import { test, expect } from "./fixtures" — NOT from
// "@playwright/test" — so the seed + cleanup apply automatically.

import { test as base, expect } from "@playwright/test";
import type { BrowserContext } from "@playwright/test";

// Public anon key + URL — these ARE in the deployed JS bundle, not secrets.
// Hardcoding here so tests don't depend on env loading. Swap to env vars if
// these ever rotate or vary per environment.
const SUPABASE_URL = "https://ldpvfolmloexlmeoqkxo.supabase.co";
const SUPABASE_ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkcHZmb2xtbG9leGxtZW9xa3hvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2ODM3NjIsImV4cCI6MjA5MjI1OTc2Mn0.UGbup57Kcv0r5eoQB1elju7DEk_moQJQZnSHkfuGRKE";

async function deletePlaywrightAnnotations(): Promise<void> {
  // Best-effort: do not block the test on cleanup failure.
  try {
    await fetch(
      `${SUPABASE_URL}/rest/v1/annotations?author_name=eq.playwright`,
      {
        method: "DELETE",
        headers: {
          apikey: SUPABASE_ANON,
          Authorization: `Bearer ${SUPABASE_ANON}`,
          "Accept-Profile": "operator_ui",
          "Content-Profile": "operator_ui",
          Prefer: "return=minimal",
        },
      },
    );
  } catch {
    // swallow; the test will surface the issue if cleanup actually mattered
  }
}

type Fixtures = {
  context: BrowserContext;
};

export const test = base.extend<Fixtures>({
  context: async ({ context }, use) => {
    await deletePlaywrightAnnotations();
    await context.addInitScript(() => {
      window.localStorage.setItem("operatorName", "playwright");
    });
    await use(context);
    // After the test, also clean up so the next run starts fresh even
    // if the next run uses a different fixture file.
    await deletePlaywrightAnnotations();
  },
});

export { expect };
