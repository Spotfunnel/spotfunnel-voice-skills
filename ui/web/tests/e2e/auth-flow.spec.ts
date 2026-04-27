// M22 — auth flow e2e.
//
// Uses the BASE Playwright `test` (no auto-session injection) for the
// unauthenticated checks; the fixtures-injected `test` for the post-login
// header check. Avoids inheriting the seeded cookie when we want to assert
// "no session → redirect".

import { test as baseTest, expect as baseExpect } from "@playwright/test";
import { test, expect } from "./fixtures";

baseTest.describe("auth flow — unauthenticated", () => {
  baseTest("visiting / redirects to /login", async ({ page }) => {
    await page.goto("/");
    await baseExpect(page).toHaveURL(/\/login(\?|$)/);
  });

  baseTest(
    "visiting /c/test-roster redirects to /login",
    async ({ page }) => {
      await page.goto("/c/test-roster");
      await baseExpect(page).toHaveURL(/\/login(\?|$)/);
    },
  );

  baseTest(
    "non-allowlist email is rejected client-side",
    async ({ page }) => {
      await page.goto("/login");
      await page.getByTestId("login-email").fill("intruder@example.com");
      await page.getByTestId("login-submit").click();
      await baseExpect(page.getByTestId("login-error")).toContainText(
        /allowlist/i,
      );
      // Must NOT have flipped to the "sent" state.
      await baseExpect(page.getByTestId("login-sent")).toHaveCount(0);
    },
  );
});

test.describe("auth flow — authenticated", () => {
  test("header shows signed-in email + sign-out link", async ({ page }) => {
    await page.goto("/");
    // Header is server-rendered from cookie; element must be present.
    await expect(page.getByTestId("header-email")).toContainText("@");
    await expect(page.getByTestId("header-logout")).toBeVisible();
  });
});
