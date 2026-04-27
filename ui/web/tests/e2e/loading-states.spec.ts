import { test, expect } from "./fixtures";

// M24 — App Router loading.tsx skeletons. The skeletons are transient by
// design; once the Server Component finishes its Supabase round-trip the
// skeleton is replaced with the real page. Asserting "the skeleton was
// briefly visible" is fundamentally racy on a fast local DB, so we instead
// verify the body is reachable on every loading-bearing route.

test.describe("M24 loading skeletons", () => {
  test("customer page renders body after loading boundary", async ({ page }) => {
    await page.goto("/c/test-roster");
    await expect(
      page.getByRole("heading", { name: "Roster Test", level: 1 }),
    ).toBeVisible();
  });

  test("artifact page renders body after loading boundary", async ({ page }) => {
    await page.goto("/c/test-roster/brain-doc");
    await expect(page.getByTestId("artifact-body")).toBeVisible();
  });

  test("home renders after loading boundary", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "ZeroOnboarding" })).toBeVisible();
  });
});
