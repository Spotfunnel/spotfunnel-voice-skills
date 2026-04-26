import Link from "next/link";

export type ChapterRowProps = {
  number: number;
  name: string;
  // null = chapter not yet generated for this run; rendered muted, not linked.
  href: string | null;
  // null = no annotations data (renders "—"); number = open-annotation count.
  annotationCount: number | null;
};

export function ChapterRow({ number, name, href, annotationCount }: ChapterRowProps) {
  const countLabel =
    annotationCount === null
      ? "—"
      : annotationCount === 1
        ? "1 annotation"
        : `${annotationCount} annotations`;

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
      <span className="text-sm text-[#6B6B6B]">{countLabel}</span>
      <span className="ml-6 text-[#6B6B6B]">→</span>
    </Link>
  );
}
