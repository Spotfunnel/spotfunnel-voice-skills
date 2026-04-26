import { test, expect } from "./fixtures";

// Drag-select → Comment chip → composer → save → highlight persists.
//
// localStorage seed for OperatorNameGate is provided by ./fixtures.
// No automated cleanup yet — leftover rows are author_name='playwright'
// and easy to clean via SQL. M7 follow-up: add an afterEach that deletes
// by author_name + comment text.

const TARGET_SENTENCE =
  "This is the brain doc body for the test-roster customer.";
const COMMENT_TEXT = "M6 e2e test annotation";

test.describe("annotation flow", () => {
  test("drag-select, comment, save, highlight persists across reload", async ({
    page,
  }) => {
    await page.goto("/c/test-roster/brain-doc");

    // Confirm the body rendered before we try to select inside it.
    const body = page.getByTestId("artifact-body");
    await expect(body).toBeVisible();
    await expect(
      page.getByText(TARGET_SENTENCE, { exact: false }),
    ).toBeVisible();

    // Programmatically place a Range over the target sentence within the
    // article element, then dispatch a mouseup on the article so the
    // ArtifactReader's handler picks up the live selection.
    await page.evaluate(
      ({ sentence }) => {
        const article = document.querySelector(
          '[data-testid="artifact-body"]',
        ) as HTMLElement | null;
        if (!article) throw new Error("artifact-body not found");
        // Walk text nodes, find one containing the sentence, build a Range.
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
      { sentence: TARGET_SENTENCE },
    );

    // Comment chip floats above selection.
    const chip = page.getByTestId("annotation-chip");
    await expect(chip).toBeVisible();
    await chip.click();

    // Composer appears with a textarea.
    const textarea = page.getByTestId("annotation-textarea");
    await expect(textarea).toBeVisible();
    await textarea.fill(COMMENT_TEXT);
    await textarea.press("Control+Enter");

    // Composer dismisses + a <mark> appears around the selected sentence.
    await expect(page.getByTestId("annotation-composer")).toHaveCount(0);
    const mark = page.locator("mark").filter({ hasText: TARGET_SENTENCE });
    await expect(mark.first()).toBeVisible();

    // Reload — highlight survives (proves persistence via Supabase + the
    // server-side annotation fetch on next render).
    await page.reload();
    const markAfter = page.locator("mark").filter({ hasText: TARGET_SENTENCE });
    await expect(markAfter.first()).toBeVisible();
  });
});
