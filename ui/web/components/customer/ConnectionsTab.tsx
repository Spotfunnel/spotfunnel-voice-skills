import {
  extractDashboard,
  extractTelephony,
  findCheck,
  summariseTool,
  truncateUuid,
  type AgentToolRow,
  type CheckRow,
  type RunStateLike,
} from "@/lib/inspect-extractors";
import { SectionHeader } from "./SectionHeader";
import { FieldRow } from "./FieldRow";

// Detail view of every external resource the agent touches. Same
// typographic discipline as Overview cards but with raw values + full
// URLs (truncated with hover-overflow). UUIDs in mono.

function ToolEntry({ tool }: { tool: AgentToolRow }) {
  const display = summariseTool(tool);
  return (
    <div className="py-4 border-t border-[#F0F0EC] first:border-t-0">
      <div className="flex items-baseline justify-between gap-4">
        <h3 className="text-[15px] text-[#1A1A1A] font-medium">{display.prettyName}</h3>
        <span className="font-mono text-[11px] text-[#9A9A92]">
          {truncateUuid(display.ultravoxToolId)}
        </span>
      </div>
      <div className="mt-2">
        <FieldRow label="Routes to" mono>
          {display.displayValue}
        </FieldRow>
        <FieldRow label="Agent" mono empty={!display.attachedToAgentId}>
          {truncateUuid(display.attachedToAgentId)}
        </FieldRow>
        {display.updatedAt ? (
          <FieldRow label="Updated">
            <span className="text-[#7A7A72]">{display.updatedAt}</span>
          </FieldRow>
        ) : null}
      </div>
    </div>
  );
}

export function ConnectionsTab({
  state,
  checks,
  tools,
}: {
  state: RunStateLike | null;
  checks: ReadonlyArray<CheckRow>;
  tools: ReadonlyArray<AgentToolRow>;
}) {
  const tel = extractTelephony(state, checks);
  const dash = extractDashboard(checks);
  const n8nCheck = findCheck(checks, "n8n-error-workflow-active");

  return (
    <div className="mt-2" data-testid="tab-connections">
      {/* Tools */}
      <section className="py-8 border-t border-[#EDECE6]" data-testid="connections-tools">
        <SectionHeader title="Tools" />
        <div className="mt-4">
          {tools.length === 0 ? (
            <p className="text-[14px] text-[#7A7A72]">
              No base tools attached. Operator runs /base-agent Stage 6.5 to add transfer + take-message.
            </p>
          ) : (
            <div className="-mt-4">
              {tools.map((t) => (
                <ToolEntry key={t.id} tool={t} />
              ))}
            </div>
          )}
        </div>
      </section>

      {/* Telephony */}
      <section className="py-8 border-t border-[#EDECE6]" data-testid="connections-telephony">
        <SectionHeader title="Telephony" />
        <div className="mt-4">
          {tel.phone ? (
            <>
              <FieldRow label="DID" mono>{tel.phoneFormatted ?? tel.phone}</FieldRow>
              <FieldRow label="Area code" mono empty={!tel.areaCode}>{tel.areaCode}</FieldRow>
              <FieldRow label="TeXML app" mono empty={!tel.texmlAppId}>{truncateUuid(tel.texmlAppId)}</FieldRow>
              <FieldRow label="Voice URL" mono empty={!tel.voiceUrl}>
                <span className="block break-all">{tel.voiceUrl}</span>
              </FieldRow>
              <FieldRow label="Status callback" mono empty={!tel.statusCallback}>
                <span className="block break-all">{tel.statusCallback}</span>
              </FieldRow>
            </>
          ) : (
            <p className="text-[14px] text-[#7A7A72]">No DID claimed.</p>
          )}
        </div>
      </section>

      {/* Dashboard */}
      <section className="py-8 border-t border-[#EDECE6]" data-testid="connections-dashboard">
        <SectionHeader title="Dashboard workspace" />
        <div className="mt-4">
          {dash.workspaceExists || dash.primaryUserExists ? (
            <>
              <FieldRow label="Workspace" empty={!dash.workspaceDetail}>
                <span className="block">{dash.workspaceDetail}</span>
              </FieldRow>
              <FieldRow label="Primary user" empty={!dash.primaryUserDetail}>
                <span className="block">{dash.primaryUserDetail}</span>
              </FieldRow>
            </>
          ) : (
            <p className="text-[14px] text-[#7A7A72]">No customer-facing dashboard wired.</p>
          )}
        </div>
      </section>

      {/* n8n */}
      <section className="py-8 border-t border-[#EDECE6]" data-testid="connections-n8n">
        <SectionHeader title="n8n error wiring" />
        <div className="mt-4">
          {n8nCheck ? (
            <FieldRow label="Status">
              <span className="text-[#1A1A1A]">{n8nCheck.detail}</span>
            </FieldRow>
          ) : (
            <p className="text-[14px] text-[#7A7A72]">No n8n verification recorded.</p>
          )}
        </div>
      </section>
    </div>
  );
}
