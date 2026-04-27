import { test, expect } from "./fixtures";

// M24 Fix 6 — drag-select grace period. Operator drag-selects a sentence,
// then clicks elsewhere before clicking "Comment". Pre-M24 the chip
// vanished silently and the work was lost. M24 keeps the chip visible for
// 3 seconds in a "stale-but-recoverable" state; clicking it within that
// window restores the prior anchor and opens the composer.

const TARGET = "This is the brain doc body for the test-roster customer.";

async function selectSentence(page: import("@playwright/test").Page, sentence: string): Promise<void> {
  await page.evaluate(
    ({ s }) => {
      const article = document.querySelector(
        '[data-testid="artifact-body"]',
      ) as HTMLElement | null;
      if (!article) throw new Error("no body");
      const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
      let node: Node | null = walker.nextNode();
      while (node) {
        const txt = (node as Text).data;
        const idx = txt.indexOf(s);
        if (idx !== -1) {
          const range = document.createRange();
          range.setStart(node, idx);
          range.setEnd(node, idx + s.length);
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
    { s: sentence },
  );
}

test.describe("M24 drag-select grace", () => {
  test("clicking outside keeps a stale chip; clicking the stale chip opens composer with prior selection", async ({
    page,
  }) => {
    await page.goto("/c/test-roster/brain-doc");
    await expect(page.getByTestId("artifact-body")).toBeVisible();

    // 1. Programmatic select sentence -> chip visible.
    await selectSentence(page, TARGET);
    const freshChip = page.getByTestId("annotation-chip");
    await expect(freshChip).toBeVisible();

    // 2. Click outside the article (the body) — collapse the live selection
    // and trigger the chip→stale-chip transition. Use a manual click via
    // mousedown + mouseup at a point definitely outside the article.
    await page.evaluate(() => {
      const sel = window.getSelection();
      sel?.removeAllRanges();
      // Simulate a mousedown anywhere outside the article — the component
      // listens at document level for the chip→stale transition.
      const ev = new MouseEvent("mousedown", {
        bubbles: true,
        cancelable: true,
        clientX: 5,
        clientY: 5,
      });
      document.body.dispatchEvent(ev);
    });

    // 3. Stale chip is visible (and the fresh chip is gone).
    const staleChip = page.getByTestId("annotation-chip-stale");
    await expect(staleChip).toBeVisible();
    await expect(page.getByTestId("annotation-chip")).toHaveCount(0);

    // 4. Click the stale chip → composer opens with the prior quote.
    await staleChip.click();
    const composer = page.getByTestId("annotation-composer");
    await expect(composer).toBeVisible();
    await expect(composer).toContainText(TARGET.slice(0, 60));
  });

  test("stale chip auto-dismisses after the grace window", async ({ page }) => {
    await page.goto("/c/test-roster/brain-doc");
    await expect(page.getByTestId("artifact-body")).toBeVisible();

    await selectSentence(page, TARGET);
    await expect(page.getByTestId("annotation-chip")).toBeVisible();

    await page.evaluate(() => {
      const sel = window.getSelection();
      sel?.removeAllRanges();
      const ev = new MouseEvent("mousedown", {
        bubbles: true,
        cancelable: true,
        clientX: 5,
        clientY: 5,
      });
      document.body.dispatchEvent(ev);
    });

    await expect(page.getByTestId("annotation-chip-stale")).toBeVisible();
    // The grace period is 3s. Allow extra slack for CI flake.
    await expect(page.getByTestId("annotation-chip-stale")).toHaveCount(0, {
      timeout: 6000,
    });
  });
});
