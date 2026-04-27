"use client";

import { useState } from "react";

type Props = {
  coverEmailBody: string;
  attachmentName: string;
  attachmentContent: string | null;
  filenameStem: string;
};

// Posts the cover-email body + customer-context attachment to /api/email-draft,
// which forwards them to the Spotfunnel n8n workflow that creates a real Gmail
// draft on the signed-in operator's account (leo@ or kye@). On success we open
// the draft directly in a new Gmail tab — operator types the recipient and
// hits send. Replaces the previous .eml download flow.
export function DraftEmailButton({
  coverEmailBody,
  attachmentName,
  attachmentContent,
  filenameStem,
}: Props) {
  const [status, setStatus] = useState<"idle" | "creating" | "error">("idle");
  const [error, setError] = useState<string | null>(null);

  async function handleClick() {
    // Open the popup synchronously inside the user-gesture window. Safari and
    // Firefox Mobile block window.open() if it lands AFTER an `await`, so we
    // claim the tab now and rewrite its location once n8n responds. If the
    // browser blocks even this synchronous call, popup is null and we fall
    // back to inline error UI with a clickable link.
    const popup = window.open("about:blank", "_blank", "noopener,noreferrer");

    setStatus("creating");
    setError(null);

    const subjectMatch = coverEmailBody.match(/^Subject:\s*(.+)$/m);
    const subject = subjectMatch
      ? subjectMatch[1].trim()
      : `${filenameStem} — onboarding`;

    // Drop the Subject line + any operator-scaffolding line that points at the
    // local filesystem path of the attachment. Both were artefacts of the old
    // copy/paste workflow; with a real attachment they're noise.
    const body = coverEmailBody
      .replace(/^Subject:.*\r?\n?/m, "")
      .replace(/^.*[A-Za-z]:[\\/].*\.md.*\(attach this file:.*\)\s*$/m, "")
      .trimStart();

    let attachment_b64 = "";
    if (attachmentContent) {
      const utf8 = new TextEncoder().encode(attachmentContent);
      let bin = "";
      for (const b of utf8) bin += String.fromCharCode(b);
      attachment_b64 = btoa(bin);
    }

    function fail(message: string) {
      popup?.close();
      setStatus("error");
      setError(message);
    }

    let res: Response;
    try {
      res = await fetch("/api/email-draft", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          subject,
          body,
          attachment_name: attachmentName,
          attachment_b64,
        }),
      });
    } catch (err) {
      fail(err instanceof Error ? err.message : "network_error");
      return;
    }

    if (!res.ok) {
      const errJson = await res.json().catch(() => ({}));
      fail(errJson.error || `HTTP ${res.status}`);
      return;
    }

    const data = (await res.json()) as {
      thread_id?: string;
      message_id?: string;
      account?: string;
    };
    const threadId = data.thread_id || data.message_id;
    const account = data.account ?? "";
    if (!threadId || !account) {
      fail("draft created but n8n didn't return a thread_id/account");
      return;
    }
    const draftUrl = `https://mail.google.com/mail/u/?authuser=${encodeURIComponent(account)}#drafts/${threadId}`;
    if (popup) {
      popup.location.href = draftUrl;
    } else {
      // Popup-blocker swallowed our window.open. Surface a fallback link so
      // the operator can still reach the draft with a single click.
      setStatus("error");
      setError(`popup blocked — open: ${draftUrl}`);
      return;
    }
    setStatus("idle");
  }

  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        onClick={handleClick}
        disabled={status === "creating"}
        className="text-xs text-[#1A1A1A] border border-[#1A1A1A]/30 hover:border-[#1A1A1A] hover:bg-[#1A1A1A] hover:text-white px-3 py-1.5 rounded transition-colors disabled:opacity-60 disabled:cursor-not-allowed"
        data-testid="draft-email-button"
        title="Create a Gmail draft on your account with subject, body, and attachment pre-filled. Opens in a new tab."
      >
        {status === "creating" ? "Creating draft…" : "Open in Gmail"}
      </button>
      {error ? (
        <span
          className="text-xs text-red-600"
          data-testid="draft-email-error"
        >
          {error}
        </span>
      ) : null}
    </div>
  );
}
