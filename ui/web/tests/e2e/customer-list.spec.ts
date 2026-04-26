import { test, expect } from "./fixtures";

test("customer list renders both seeded customers", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Customer A", level: 2 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Customer B", level: 2 })).toBeVisible();
});
