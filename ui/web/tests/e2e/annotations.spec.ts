import { test, expect } from "./fixtures";

// Drag-select → Comment chip → composer → save → highlight persists.
//
// localStorage seed for OperatorNameGate is provided by ./fixtures.
// Cleanup of any annotation rows authored by "playwright" runs in the
// fixture beforeEach + afterEach so flake doesn't bleed between tests.

const TARGET_SENTENCE =
  "This is the brain doc body for the test-roster customer.";
const COMMENT_TEXT = "M6 e2e test annotation";
const RAIL_COMMENT = "M7 rail e2e";

// Programmatic select-then-mouseup so we don't depend on real-mouse drag
// geometry. Used by both the M6 and M7 tests.
async function selectSentenceAndMouseUp(
  page: import("@playwright/test").Page,
  sentence: string,
): Promise<void> {
  await page.evaluate(
    ({ sentence }) => {
      const article = document.querySelector(
        '[data-testid="artifact-body"]',
      ) as HTMLElement | null;
      if (!article) throw new Error("artifact-body not found");
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
          if (!sel) throw new Error("no selection api");
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
      throw new Error("target sentence not found in article");
    },
    { sentence },
  );
}

test.describe("annotation flow", () => {
  test("drag-select, comment, save, highlight persists across reload", async ({
    page,
  }) => {
    await page.goto("/c/test-roster/brain-doc");

    const body = page.getByTestId("artifact-body");
    await expect(body).toBeVisible();
    await expect(
      page.getByText(TARGET_SENTENCE, { exact: false }),
    ).toBeVisible();

    await selectSentenceAndMouseUp(page, TARGET_SENTENCE);

    const chip = page.getByTestId("annotation-chip");
    await expect(chip).toBeVisible();
    await chip.click();

    const textarea = page.getByTestId("annotation-textarea");
    await expect(textarea).toBeVisible();
    await textarea.fill(COMMENT_TEXT);
    await textarea.press("Control+Enter");

    await expect(page.getByTestId("annotation-composer")).toHaveCount(0);
    const mark = page.locator("mark").filter({ hasText: TARGET_SENTENCE });
    await expect(mark.first()).toBeVisible();

    await page.reload();
    const markAfter = page.locator("mark").filter({ hasText: TARGET_SENTENCE });
    await expect(markAfter.first()).toBeVisible();
  });

  test("rail: A toggle, resolve dims highlight, delete removes it, restore", async ({
    page,
  }) => {
    await page.goto("/c/test-roster/brain-doc");
    await expect(page.getByTestId("artifact-body")).toBeVisible();

    // Save an annotation (re-uses the M6 flow).
    await selectSentenceAndMouseUp(page, TARGET_SENTENCE);
    const chip = page.getByTestId("annotation-chip");
    await expect(chip).toBeVisible();
    await chip.click();
    const textarea = page.getByTestId("annotation-textarea");
    await expect(textarea).toBeVisible();
    await textarea.fill(RAIL_COMMENT);
    await textarea.press("Control+Enter");
    await expect(page.getByTestId("annotation-composer")).toHaveCount(0);

    const mark = page
      .locator("mark[data-annotation-id]")
      .filter({ hasText: TARGET_SENTENCE });
    await expect(mark.first()).toBeVisible();

    // Press 'A' on the body element so the keydown isn't intercepted by any
    // focused input (selectSentence may have left focus loose).
    await page.locator("body").focus();
    await page.keyboard.press("a");
    const rail = page.getByTestId("annotation-rail");
    await expect(rail).toBeVisible();

    // The rail should list our annotation in the open bucket.
    const railItem = rail
      .getByTestId("annotation-rail-item")
      .filter({ hasText: RAIL_COMMENT });
    await expect(railItem).toBeVisible();

    // Resolve. Mark should remain in the DOM but its status attr flips
    // to 'resolved' (which we use to drive the dimmed background).
    await railItem.getByTestId("annotation-rail-resolve").click();

    // After router.refresh the rail's "open" filter has zero items; rail
    // either shows empty state OR auto-scrolls to whatever filter we keep.
    // We kept filter='open' on resolve, so item leaves the visible list.
    await expect(
      rail.getByTestId("annotation-rail-item").filter({ hasText: RAIL_COMMENT }),
    ).toHaveCount(0);

    // Mark in prose now has data-annotation-status="resolved".
    const resolvedMark = page
      .locator('mark[data-annotation-status="resolved"]')
      .filter({ hasText: TARGET_SENTENCE });
    await expect(resolvedMark.first()).toBeVisible();

    // Switch filter to "resolved" and reopen.
    await rail.getByTestId("annotation-rail-filter-resolved").click();
    const resolvedItem = rail
      .getByTestId("annotation-rail-item")
      .filter({ hasText: RAIL_COMMENT });
    await expect(resolvedItem).toBeVisible();
    await resolvedItem.getByTestId("annotation-rail-reopen").click();

    // Back to open: mark's status attribute returns to 'open'.
    await expect(
      page
        .locator('mark[data-annotation-status="open"]')
        .filter({ hasText: TARGET_SENTENCE })
        .first(),
    ).toBeVisible();

    // Switch filter back to open and delete.
    await rail.getByTestId("annotation-rail-filter-open").click();
    const openItem = rail
      .getByTestId("annotation-rail-item")
      .filter({ hasText: RAIL_COMMENT });
    await expect(openItem).toBeVisible();
    await openItem.getByTestId("annotation-rail-delete").click();

    // Mark disappears from prose entirely (deleted = not rendered).
    await expect(
      page.locator("mark[data-annotation-id]").filter({ hasText: TARGET_SENTENCE }),
    ).toHaveCount(0);

    // Filter to deleted; the row reappears with a "restore" action.
    await rail.getByTestId("annotation-rail-filter-deleted").click();
    const deletedItem = rail
      .getByTestId("annotation-rail-item")
      .filter({ hasText: RAIL_COMMENT });
    await expect(deletedItem).toBeVisible();
    await expect(
      deletedItem.getByTestId("annotation-rail-restore"),
    ).toBeVisible();

    // Esc closes the rail.
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("annotation-rail")).toHaveCount(0);
  });
});
