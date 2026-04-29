import { SectionHeader } from "./SectionHeader";
import { truncateUuid } from "@/lib/inspect-extractors";

// Audit log — operator_ui.deployment_log filtered by customer_slug. Each
// row is a single typographic line with status glyph, mono target_id,
// and a lighter prose summary. No boxed table.

export type DeploymentLogRow = {
  id: string;
  stage: number;
  system: string;
  action: string;
  target_kind: string;
  target_id: string | null;
  inverse_op: string;
  status: "active" | "reversed" | "reverse_failed" | "reverse_skipped" | string;
  created_at: string;
};

function statusGlyph(status: string): { ch: string; color: string; label: string } {
  switch (status) {
    case "active": return { ch: "●", color: "#3CB371", label: "active" };
    case "reversed": return { ch: "○", color: "#9A9A92", label: "reversed" };
    case "reverse_failed": return { ch: "×", color: "#C0392B", label: "reverse failed" };
    case "reverse_skipped": return { ch: "·", color: "#C0C0BA", label: "skipped" };
    default: return { ch: "·", color: "#C0C0BA", label: status };
  }
}

export function AuditTab({ rows }: { rows: ReadonlyArray<DeploymentLogRow> }) {
  if (rows.length === 0) {
    return (
      <div className="mt-2 py-8 border-t border-[#EDECE6]" data-testid="tab-audit">
        <SectionHeader title="Audit log" />
        <p className="mt-4 text-[14px] text-[#7A7A72]">
          No deployment_log entries — this customer predates the audit-log
          migration (2026-04-28), or the run was on the legacy local-file backend.
        </p>
      </div>
    );
  }

  const counts = rows.reduce(
    (acc, r) => {
      acc[r.status] = (acc[r.status] ?? 0) + 1;
      return acc;
    },
    {} as Record<string, number>,
  );
  const summary = ["active", "reversed", "reverse_failed", "reverse_skipped"]
    .filter((s) => (counts[s] ?? 0) > 0)
    .map((s) => `${counts[s]} ${s.replace("_", " ")}`)
    .join(" · ");

  return (
    <div className="mt-2 py-8 border-t border-[#EDECE6]" data-testid="tab-audit">
      <SectionHeader title="Audit log" />
      <p className="mt-2 text-[12px] text-[#9A9A92]">
        {rows.length} {rows.length === 1 ? "entry" : "entries"} · {summary}
      </p>
      <ul className="mt-4 divide-y divide-[#F0F0EC]">
        {rows.map((r) => {
          const g = statusGlyph(r.status);
          return (
            <li
              key={r.id}
              className="flex items-baseline gap-4 py-3 text-[13.5px]"
              data-testid="audit-row"
              data-status={r.status}
            >
              <span
                className="font-mono w-[14px] text-center"
                style={{ color: g.color }}
                aria-label={g.label}
              >
                {g.ch}
              </span>
              <span className="font-mono text-[12px] text-[#9A9A92] w-[88px]">
                stage {r.stage}
              </span>
              <span className="text-[#1A1A1A] flex-1 truncate">
                {r.system} · {r.action} · {r.target_kind}
              </span>
              <span className="font-mono text-[12px] text-[#9A9A92] w-[100px] text-right">
                {truncateUuid(r.target_id)}
              </span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
