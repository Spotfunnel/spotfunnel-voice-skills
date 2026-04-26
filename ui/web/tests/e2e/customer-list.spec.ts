import { test, expect } from "@playwright/test";

test.beforeEach(async ({ context }) => {
  // Bypass the OperatorNameGate (M6) so we can render pages directly.
  await context.addInitScript(() => {
    window.localStorage.setItem("operatorName", "playwright");
  });
});

test("customer list renders both seeded customers", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Customer A", level: 2 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Customer B", level: 2 })).toBeVisible();
});
