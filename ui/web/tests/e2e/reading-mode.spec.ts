import { test, expect } from "@playwright/test";

test("reading mode renders artifact markdown with header + footer nav", async ({ page }) => {
  await page.goto("/c/test-roster/brain-doc");

  // Top bar — back link with the customer name + the chapter title.
  const backLink = page.getByRole("link", { name: /Roster Test/ });
  await expect(backLink).toBeVisible();
  await expect(backLink).toHaveAttribute("href", "/c/test-roster");
  await expect(page.getByText("Brain doc", { exact: true })).toBeVisible();

  // Body — markdown rendered visibly (seeded fixture text).
  await expect(
    page.getByText("This is the brain doc body for the test-roster customer."),
  ).toBeVisible();

  // Footer — Next link points at system-prompt (next available chapter).
  const nextLink = page.getByRole("link", { name: /Next: System prompt/ });
  await expect(nextLink).toBeVisible();
  await expect(nextLink).toHaveAttribute("href", "/c/test-roster/system-prompt");
});
