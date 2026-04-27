"use client";

import { useEffect, useRef, useState } from "react";

// Small reusable copy-to-clipboard button. Used by the Inspect view's
// remediation rows + empty state. Briefly shows "copied" inline (1.5s)
// instead of mounting a global toast — this is co-located with the row,
// the operator already knows where they clicked.
export function CopyCommandButton({
  command,
  label = "copy",
  compact = false,
}: {
  command: string;
  label?: string;
  compact?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  async function onClick() {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      // ignore
    }
    setCopied(true);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      setCopied(false);
      timerRef.current = null;
    }, 1500);
  }

  const cls = compact
    ? "shrink-0 text-xs text-[#6B6B6B] hover:text-[#1A1A1A] underline underline-offset-2"
    : "text-sm text-[#1A1A1A] underline underline-offset-4 hover:text-[#6B6B6B]";

  return (
    <button
      type="button"
      onClick={() => void onClick()}
      className={cls}
      data-testid="copy-command-button"
      aria-live="polite"
    >
      {copied ? "copied" : label}
    </button>
  );
}
