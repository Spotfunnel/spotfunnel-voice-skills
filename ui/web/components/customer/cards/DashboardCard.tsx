import { extractDashboard, type CheckRow } from "@/lib/inspect-extractors";
import { SectionHeader, type SectionStatus } from "../SectionHeader";
import { FieldRow } from "../FieldRow";
import { CopyCommandButton } from "@/components/CopyCommandButton";

// Customer-facing dashboard card. Workspace + primary user existence with
// the raw detail strings preserved (verify.py emits free-text — once we
// add a structured `data` field per check we'll parse out workspace name,
// plan, agent_ids count etc. directly).

export function DashboardCard({
  checks,
  slug,
}: {
  checks: ReadonlyArray<CheckRow>;
  slug: string;
}) {
  const info = extractDashboard(checks);
  const present = info.workspaceExists || info.primaryUserExists;
  const status: SectionStatus =
    info.workspaceExists && info.primaryUserExists
      ? "pass"
      : info.workspaceExists || info.primaryUserExists
        ? "partial"
        : "none";

  return (
    <section
      className="border-t border-[#EDECE6] py-8"
      data-testid="card-dashboard"
    >
      <SectionHeader title="Dashboard" status={present ? status : "none"} />
      <div className="mt-4">
        {present ? (
          <>
            <FieldRow label="Workspace" empty={!info.workspaceDetail}>
              <span className="block">{info.workspaceDetail}</span>
            </FieldRow>
            <FieldRow label="Primary user" empty={!info.primaryUserDetail}>
              <span className="block">{info.primaryUserDetail}</span>
            </FieldRow>
          </>
        ) : (
          <div>
            <p className="text-[14px] text-[#7A7A72]">
              Dashboard workspace not yet wired.
            </p>
            <div className="mt-3">
              <CopyCommandButton
                command={`/onboard-customer ${slug}`}
                label={`Copy /onboard-customer ${slug}`}
              />
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
