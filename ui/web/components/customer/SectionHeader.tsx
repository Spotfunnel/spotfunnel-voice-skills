// Small typographic header used by every tab section + resource card.
// Mirrors the existing "## Read" / "## Verification checks" headers — 11px
// uppercase tracking-[0.18em] muted-stone — with an optional status dot
// to its right. Status dot uses the existing dotHex() palette so the
// whole UI stays semantically consistent.

import { dotHex } from "@/lib/verification";

export type SectionStatus = "pass" | "fail" | "partial" | "skip" | "none";

const STATUS_TO_DOT: Record<SectionStatus, "green" | "red" | "amber" | "gray"> = {
  pass: "green",
  fail: "red",
  partial: "amber",
  skip: "gray",
  none: "gray",
};

export function SectionHeader({
  title,
  status,
}: {
  title: string;
  status?: SectionStatus;
}) {
  return (
    <div className="flex items-center gap-3">
      <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
        {title}
      </h2>
      {status ? (
        <span
          className="inline-block w-[6px] h-[6px] rounded-full flex-shrink-0"
          style={{ backgroundColor: dotHex(STATUS_TO_DOT[status]) }}
          aria-label={`status: ${status}`}
        />
      ) : null}
    </div>
  );
}
