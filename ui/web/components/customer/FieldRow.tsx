// One typographic row inside a resource card: mono muted label on the left
// (~120px), value on the right. The two-column rhythm is what gives the
// cards their "operational manifest" feel — values align across rows even
// when labels are different lengths.

import type { ReactNode } from "react";

export function FieldRow({
  label,
  children,
  mono,
  empty,
}: {
  label: string;
  children: ReactNode;
  // Render value column in mono — for IDs, phone numbers, URLs.
  mono?: boolean;
  // Force the empty-state em-dash. Use when children would render nothing
  // useful but you still want the row present for grid alignment.
  empty?: boolean;
}) {
  return (
    <div className="flex items-baseline gap-4 py-2 text-[14px] text-[#1A1A1A]">
      <div className="w-[120px] flex-shrink-0 font-mono text-[12px] text-[#9A9A92] uppercase tracking-[0.05em]">
        {label}
      </div>
      <div className={`flex-1 min-w-0 break-words ${mono ? "font-mono text-[13px]" : ""}`}>
        {empty ? <span className="text-[#C0C0BA]">—</span> : children}
      </div>
    </div>
  );
}
