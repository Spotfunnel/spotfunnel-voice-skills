// Helpers for the M20 Inspect view. Status dot color derives from the
// verification summary {pass, fail, skip}:
//   - no row → gray (unfilled)
//   - any fail → red
//   - any skip (no fail) → amber
//   - all pass → green

import type { VerificationSummary } from "./types";

export type DotColor = "green" | "amber" | "red" | "gray";

export function dotColor(summary: VerificationSummary | null | undefined): DotColor {
  if (!summary) return "gray";
  const fail = numberOr(summary.fail, 0);
  const skip = numberOr(summary.skip, 0);
  const pass = numberOr(summary.pass, 0);
  if (fail > 0) return "red";
  if (skip > 0) return "amber";
  if (pass > 0) return "green";
  // Empty summary (no checks at all) — treat as gray.
  return "gray";
}

function numberOr(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

// Tailwind-friendly hex. Matches the palette used elsewhere in the operator
// UI (warm off-white, single accent — colors here are status-only).
export function dotHex(c: DotColor): string {
  switch (c) {
    case "green":
      return "#3CB371";
    case "amber":
      return "#D9A441";
    case "red":
      return "#C0392B";
    case "gray":
      return "#C0C0BA";
  }
}
