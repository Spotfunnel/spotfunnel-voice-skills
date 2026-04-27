import { test, expect } from "./fixtures";

// M24 — global not-found.tsx replaces the generic Next.js 404 page.

test.describe("M24 not-found page", () => {
  test("unknown customer slug renders custom 404 with back link", async ({ page }) => {
    await page.goto("/c/nonexistent-slug-xyz");

    await expect(page.getByTestId("not-found")).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "Customer not found" }),
    ).toBeVisible();

    const back = page.getByTestId("not-found-back-link");
    await expect(back).toBeVisible();
    await expect(back).toHaveAttribute("href", "/");
  });

  test("unknown top-level path renders custom 404", async ({ page }) => {
    await page.goto("/totally-not-a-route");
    await expect(page.getByTestId("not-found")).toBeVisible();
  });
});
