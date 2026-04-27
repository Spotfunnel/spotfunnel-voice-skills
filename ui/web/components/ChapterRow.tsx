import Link from "next/link";

export type ChapterRowProps = {
  number: number;
  name: string;
  // null = chapter not yet generated for this run; rendered muted, not linked.
  href: string | null;
  // null = no annotations data; openCount/resolvedCount = per-status totals.
  // Open count gets emphasis (it's actionable); resolved count surfaces only
  // when there are no open comments (so the operator sees the engagement
  // history even after everything's been worked through).
  openCount: number | null;
  resolvedCount: number | null;
};

function formatCount(n: number, label: string): string {
  return `${n} ${label}`;
}

export function ChapterRow({
  number,
  name,
  href,
  openCount,
  resolvedCount,
}: ChapterRowProps) {
  let countLabel: string;
  let countTone: string;
  if (openCount === null) {
    countLabel = "—";
    countTone = "text-[#6B6B6B]";
  } else if (openCount > 0) {
    countLabel = formatCount(openCount, openCount === 1 ? "open" : "open");
    countTone = "text-[#1A1A1A] font-medium";
  } else if ((resolvedCount ?? 0) > 0) {
    const r = resolvedCount as number;
    countLabel = formatCount(r, r === 1 ? "resolved" : "resolved");
    countTone = "text-[#9A9A92]";
  } else {
    countLabel = "—";
    countTone = "text-[#9A9A92]";
  }

  if (href === null) {
    return (
      <div className="flex items-baseline py-3 text-[#6B6B6B]">
        <span className="w-8 tabular-nums">{number}.</span>
        <span className="flex-1">{name}</span>
        <span className="text-sm italic">— not yet generated</span>
      </div>
    );
  }

  return (
    <Link
      href={href}
      className="flex items-baseline py-3 hover:bg-white transition-colors"
    >
      <span className="w-8 tabular-nums">{number}.</span>
      <span className="flex-1">{name}</span>
      <span className={`text-sm ${countTone}`}>{countLabel}</span>
      <span className="ml-6 text-[#6B6B6B]">→</span>
    </Link>
  );
}
