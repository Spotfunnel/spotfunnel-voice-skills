import Link from "next/link";
import type { CustomerSummary } from "@/lib/types";

const DOT_COLOR: Record<CustomerSummary["status"], string> = {
  pass: "#4F8C5A", // muted forest
  fail: "#A04545", // muted brick
  partial: "#B58F4D", // amber
  "in-progress": "#5C7AB8", // muted indigo — onboarding running
  none: "#D1CFC4", // pale stone — no signal
};

const DOT_LABEL: Record<CustomerSummary["status"], string> = {
  pass: "All checks passing",
  fail: "Verification failures",
  partial: "Some checks skipped",
  "in-progress": "Onboarding in progress",
  none: "Not yet verified",
};

function relativeTime(iso: string | null): string {
  if (!iso) return "no runs";
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 60_000) return "just now";
  const min = Math.floor(ms / 60_000);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 7) return `${day}d ago`;
  // Older — fall back to absolute UTC for stability across SSR/CSR.
  const d = new Date(iso);
  const dd = d.getUTCDate();
  const mon = d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" });
  const yr = d.getUTCFullYear();
  const now = new Date();
  return yr === now.getUTCFullYear() ? `${dd} ${mon}` : `${dd} ${mon} ${yr}`;
}

export function CustomerCard({ customer }: { customer: CustomerSummary }) {
  const ago = relativeTime(customer.latest_run_at);
  const stagePart =
    customer.latest_stage !== null && customer.latest_stage < 11
      ? `stage ${customer.latest_stage}/11`
      : null;

  return (
    <Link
      href={`/c/${customer.slug}`}
      className="group flex items-center gap-8 px-2 -mx-2 py-7 border-b border-[#EDECE6] transition-colors duration-150 hover:bg-[#F4F2EC]"
      data-testid={`customer-card-${customer.slug}`}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline gap-3">
          <h2 className="truncate text-[28px] font-medium tracking-tight leading-none text-[#1A1A1A]">
            {customer.name}
          </h2>
          <span
            className="inline-block w-[7px] h-[7px] rounded-full flex-shrink-0 translate-y-[-3px]"
            style={{ backgroundColor: DOT_COLOR[customer.status] }}
            aria-label={DOT_LABEL[customer.status]}
            title={DOT_LABEL[customer.status]}
          />
        </div>
        <p className="mt-2 truncate font-mono text-[12px] text-[#9A9A92]">
          {customer.slug}
        </p>
      </div>

      <div className="flex items-center gap-3 whitespace-nowrap text-[12px] text-[#7A7A72]">
        {customer.run_count > 0 ? (
          <>
            <span>
              {customer.run_count} run{customer.run_count === 1 ? "" : "s"}
            </span>
            <span className="text-[#D8D5CC]">·</span>
          </>
        ) : null}
        <span>{ago}</span>
        {stagePart ? (
          <>
            <span className="text-[#D8D5CC]">·</span>
            <span>{stagePart}</span>
          </>
        ) : null}
        {customer.open_annotations > 0 ? (
          <>
            <span className="text-[#D8D5CC]">·</span>
            <span className="font-medium text-[#1A1A1A]">
              {customer.open_annotations} open
            </span>
          </>
        ) : null}
      </div>
    </Link>
  );
}
