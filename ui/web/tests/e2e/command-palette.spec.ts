import { test, expect } from "./fixtures";

// M19 — Ctrl+K command palette.

test.describe("M19 command palette", () => {
  test("Ctrl+K opens, customer match, Enter navigates", async ({ page }) => {
    await page.goto("/");
    await page.locator("body").focus();
    await page.keyboard.press("Control+k");

    const palette = page.getByTestId("command-palette");
    await expect(palette).toBeVisible();

    const input = page.getByTestId("command-palette-input");
    await expect(input).toBeFocused();

    await input.fill("roster");
    // Wait for the customer entry to appear in the list.
    const customerItems = page.locator(
      '[data-testid="command-palette-item"][data-kind="customer"]',
    );
    await expect(customerItems.first()).toBeVisible();

    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/c\/test-roster$/);
  });

  test("Esc closes the palette", async ({ page }) => {
    await page.goto("/");
    await page.locator("body").focus();
    await page.keyboard.press("Control+k");
    await expect(page.getByTestId("command-palette")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("command-palette")).toHaveCount(0);
  });

  test("action results: copy /base-agent verify command", async ({ page, context }) => {
    // Grant clipboard permissions before navigating.
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/c/test-roster");
    await page.locator("body").focus();
    await page.keyboard.press("Control+k");
    await expect(page.getByTestId("command-palette")).toBeVisible();

    const input = page.getByTestId("command-palette-input");
    await input.fill("verify");

    const action = page
      .getByTestId("command-palette-item")
      .filter({ hasText: "Copy /base-agent verify test-roster" });
    await expect(action.first()).toBeVisible();
    await action.first().click();

    await expect(page.getByTestId("command-palette")).toHaveCount(0);
    const clip = await page.evaluate(() => navigator.clipboard.readText());
    expect(clip).toBe("/base-agent verify test-roster");
  });

  test("annotation results in reading mode", async ({ page }) => {
    await page.goto("/c/test-roster/brain-doc");
    await expect(page.getByTestId("artifact-body")).toBeVisible();

    // Seed one annotation via the existing M6 flow so the palette has
    // something to fuzzy-match.
    const TARGET = "This is the brain doc body for the test-roster customer.";
    const COMMENT = "palette-annotation-target";
    await page.evaluate(
      ({ sentence }) => {
        const article = document.querySelector(
          '[data-testid="artifact-body"]',
        ) as HTMLElement | null;
        if (!article) throw new Error("no body");
        const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
        let node: Node | null = walker.nextNode();
        while (node) {
          const txt = (node as Text).data;
          const idx = txt.indexOf(sentence);
          if (idx !== -1) {
            const range = document.createRange();
            range.setStart(node, idx);
            range.setEnd(node, idx + sentence.length);
            const sel = window.getSelection();
            if (!sel) throw new Error("no selection");
            sel.removeAllRanges();
            sel.addRange(range);
            const rect = range.getBoundingClientRect();
            article.dispatchEvent(
              new MouseEvent("mouseup", {
                bubbles: true,
                cancelable: true,
                clientX: rect.left + rect.width / 2,
                clientY: rect.bottom,
              }),
            );
            return;
          }
          node = walker.nextNode();
        }
        throw new Error("sentence not found");
      },
      { sentence: TARGET },
    );

    const chip = page.getByTestId("annotation-chip");
    await expect(chip).toBeVisible();
    await chip.click();
    const textarea = page.getByTestId("annotation-textarea");
    await textarea.fill(COMMENT);
    await textarea.press("Control+Enter");
    await expect(page.getByTestId("annotation-composer")).toHaveCount(0);

    // Wait for the mark to render — proves the row is in the DB and the
    // server-component refresh has happened. Without this, opening the
    // palette can race with the still-pending router.refresh().
    await expect(
      page.locator("mark[data-annotation-id]").filter({ hasText: TARGET }),
    ).toBeVisible();

    // Now open the palette and search for the comment substring.
    await page.locator("body").focus();
    await page.keyboard.press("Control+k");
    await expect(page.getByTestId("command-palette")).toBeVisible();
    const input = page.getByTestId("command-palette-input");
    await input.fill("palette-anno");

    const annItem = page.locator(
      '[data-testid="command-palette-item"][data-kind="annotation"]',
    );
    await expect(annItem.first()).toBeVisible();
    await annItem.first().click();

    await expect(page.getByTestId("command-palette")).toHaveCount(0);
    // Clicking an annotation result clicks the underlying mark, which opens
    // the rail focused on that annotation.
    await expect(page.getByTestId("annotation-rail")).toBeVisible();
  });
});
