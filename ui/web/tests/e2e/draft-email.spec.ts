import { test, expect } from "./fixtures";

test("'Open in Gmail' posts to /api/email-draft and opens Gmail draft in new tab", async ({
  page,
  context,
}) => {
  let capturedBody: Record<string, unknown> | null = null;

  await page.route("**/api/email-draft", async (route) => {
    capturedBody = JSON.parse(route.request().postData() ?? "{}");
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        draft_id: "r-test-123",
        thread_id: "t-test-abc",
        message_id: "m-test-abc",
        account: "leo@getspotfunnel.com",
      }),
    });
  });

  await page.goto("/c/test-roster/cover-email");

  const button = page.getByTestId("draft-email-button");
  await expect(button).toBeVisible();
  await expect(button).toHaveText(/Open in Gmail/);

  const popupPromise = context.waitForEvent("page");
  await button.click();
  const popup = await popupPromise;
  await popup.waitForLoadState("domcontentloaded").catch(() => {});

  expect(popup.url()).toContain("mail.google.com");
  expect(popup.url()).toContain("authuser=leo%40getspotfunnel.com");
  expect(popup.url()).toContain("#drafts/t-test-abc");

  expect(capturedBody).not.toBeNull();
  expect(capturedBody).toMatchObject({
    subject: expect.any(String),
    body: expect.any(String),
  });

  await popup.close();
});
