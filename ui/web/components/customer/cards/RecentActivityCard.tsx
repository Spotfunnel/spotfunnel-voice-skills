import { SectionHeader } from "../SectionHeader";
import { maskPhone } from "@/lib/inspect-extractors";

// Recent calls card. Sources from dashboard.calls — but the dashboard
// schema may not be on the same Supabase project as operator_ui (existing
// production: SUPABASE_URL points at operator_ui project for dev installs).
// In that case we receive an empty list + a "not configured" hint.
//
// Caller phone last-4 digits show; rest masked. Outcome rendered as plain
// text. Duration in mono. Time relative.

export type RecentCall = {
  id: string;
  caller_phone: string | null;
  outcome: string | null;
  duration_sec: number | null;
  started_at: string | null;
};

function relativeTime(iso: string | null): string {
  if (!iso) return "—";
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 60_000) return "just now";
  const min = Math.floor(ms / 60_000);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return `${day}d ago`;
}

function formatDuration(sec: number | null): string {
  if (!sec || sec < 1) return "—";
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s ? `${m}m ${s}s` : `${m}m`;
}

export function RecentActivityCard({
  calls,
  configured,
}: {
  calls: ReadonlyArray<RecentCall>;
  // false when the dashboard schema isn't accessible (PGRST205 swallowed
  // upstream). Render the "not configured" hint instead of an empty list.
  configured: boolean;
}) {
  return (
    <section
      className="border-t border-[#EDECE6] py-8"
      data-testid="card-recent-activity"
    >
      <SectionHeader title="Recent activity" status={calls.length > 0 ? "pass" : "none"} />
      <div className="mt-4">
        {!configured ? (
          <p className="text-[14px] text-[#7A7A72]">
            Dashboard not configured for this install. Recent calls land in the
            customer-facing dashboard&apos;s <code className="font-mono text-[13px]">calls</code> table; once that
            project is wired (separate Supabase URL), the last 5 calls
            render here.
          </p>
        ) : calls.length === 0 ? (
          <p className="text-[14px] text-[#7A7A72]">No calls yet.</p>
        ) : (
          <ul className="divide-y divide-[#F0F0EC]">
            {calls.slice(0, 5).map((c) => (
              <li
                key={c.id}
                className="flex items-baseline gap-4 py-3 text-[13.5px]"
                data-testid="recent-call-row"
              >
                <span className="font-mono text-[12.5px] text-[#1A1A1A] w-[100px]">
                  {maskPhone(c.caller_phone)}
                </span>
                <span className="flex-1 text-[#1A1A1A] truncate">
                  {c.outcome ?? "(no outcome)"}
                </span>
                <span className="font-mono text-[12px] text-[#9A9A92] w-[60px] text-right">
                  {formatDuration(c.duration_sec)}
                </span>
                <span className="text-[12px] text-[#9A9A92] w-[80px] text-right">
                  {relativeTime(c.started_at)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
