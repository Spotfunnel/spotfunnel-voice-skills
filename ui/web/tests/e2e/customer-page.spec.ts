import { test, expect } from "@playwright/test";

test.beforeEach(async ({ context }) => {
  // Bypass the OperatorNameGate (M6) so we can render pages directly.
  await context.addInitScript(() => {
    window.localStorage.setItem("operatorName", "playwright");
  });
});

test("customer page renders 7-chapter roster", async ({ page }) => {
  await page.goto("/c/test-roster");

  // Header + run line.
  await expect(page.getByRole("heading", { name: "Roster Test", level: 1 })).toBeVisible();
  await expect(page.getByText(/Latest run · .* · stage 11\/11/)).toBeVisible();

  // Read section label.
  await expect(page.getByRole("heading", { name: "Read", level: 2 })).toBeVisible();

  // The six artifact-backed chapters render as links to the reading-mode URL.
  const links: Array<[string, string]> = [
    ["Brain doc", "/c/test-roster/brain-doc"],
    ["System prompt", "/c/test-roster/system-prompt"],
    ["Discovery prompt", "/c/test-roster/discovery-prompt"],
    ["Customer context", "/c/test-roster/customer-context"],
    ["Cover email", "/c/test-roster/cover-email"],
    ["Meeting transcript", "/c/test-roster/meeting-transcript"],
  ];
  for (const [label, href] of links) {
    const link = page.getByRole("link", { name: new RegExp(label) });
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute("href", href);
  }

  // Chapter 7 — no scrape_pages_count in run.state, so it's muted/disabled.
  await expect(page.getByText(/Scraped pages/)).toBeVisible();
  await expect(page.getByText(/— not yet generated/)).toBeVisible();

  // Footer placeholders.
  await expect(page.getByText("[ Inspect deployment ]")).toBeVisible();
  await expect(page.getByText(/Run history/)).toBeVisible();
});
