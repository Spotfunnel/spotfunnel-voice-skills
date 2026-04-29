import { AgentCard } from "./cards/AgentCard";
import { TelephonyCard } from "./cards/TelephonyCard";
import { DashboardCard } from "./cards/DashboardCard";
import { RecentActivityCard, type RecentCall } from "./cards/RecentActivityCard";
import type { CheckRow, RunStateLike } from "@/lib/inspect-extractors";

// Stack of four resource cards. Single column on mobile/narrow, 2-column
// on wide so the operator's eye can scan all four at a glance. Border-top
// separators give the cards their typographic grouping (no boxed widgets).

export function OverviewTab({
  state,
  checks,
  recentCalls,
  recentCallsConfigured,
  slug,
}: {
  state: RunStateLike | null;
  checks: ReadonlyArray<CheckRow>;
  recentCalls: ReadonlyArray<RecentCall>;
  recentCallsConfigured: boolean;
  slug: string;
}) {
  return (
    <div className="mt-2" data-testid="tab-overview">
      <AgentCard state={state} checks={checks} />
      <TelephonyCard state={state} checks={checks} slug={slug} />
      <DashboardCard checks={checks} slug={slug} />
      <RecentActivityCard calls={recentCalls} configured={recentCallsConfigured} />
    </div>
  );
}
