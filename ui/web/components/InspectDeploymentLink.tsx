import Link from "next/link";
import { dotColor, dotHex, type DotColor } from "@/lib/verification";
import type { VerificationSummary } from "@/lib/types";

type Props = {
  slug: string;
  summary: VerificationSummary | null;
};

const LABELS: Record<DotColor, string> = {
  green: "all checks passing",
  amber: "some checks skipped",
  red: "checks failing",
  gray: "not yet verified",
};

export function InspectDeploymentLink({ slug, summary }: Props) {
  const color = dotColor(summary);
  return (
    <Link
      href={`/c/${slug}/inspect`}
      className="mt-12 flex items-center gap-3 text-sm text-[#6B6B6B] hover:text-[#1A1A1A] transition-colors w-fit"
      data-testid="inspect-deployment-link"
      data-dot-color={color}
    >
      <span>[ Inspect deployment ]</span>
      <span
        aria-label={LABELS[color]}
        title={LABELS[color]}
        className="inline-block leading-none"
        style={{ color: dotHex(color) }}
        data-testid="inspect-status-dot"
      >
        ●
      </span>
    </Link>
  );
}
