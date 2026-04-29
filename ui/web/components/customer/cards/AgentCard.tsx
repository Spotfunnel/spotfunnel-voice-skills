import { aggregateStatus, extractAgentInfo, truncateUuid, type CheckRow, type RunStateLike } from "@/lib/inspect-extractors";
import { SectionHeader, type SectionStatus } from "../SectionHeader";
import { FieldRow } from "../FieldRow";

// Ultravox agent card. Surfaces voice + temperature + system-prompt size +
// the agent_id itself. Sources: runs.state.* + extracted from
// verifications.checks. NO live API calls.

export function AgentCard({
  state,
  checks,
}: {
  state: RunStateLike | null;
  checks: ReadonlyArray<CheckRow>;
}) {
  const info = extractAgentInfo(state, checks);
  const status: SectionStatus = aggregateStatus(checks, [
    "ultravox-agent-exists",
    "ultravox-voice-temperature",
    "system-prompt-matches-artifact",
  ]);

  const present = Boolean(info.agentId);
  const fullName = info.customerName && info.agentFirstName
    ? `${info.customerName.replace(/\s+/g, "")}-${info.agentFirstName}`
    : info.agentFirstName ?? null;

  return (
    <section
      className="border-t border-[#EDECE6] py-8"
      data-testid="card-agent"
    >
      <SectionHeader title="Agent" status={present ? status : "none"} />
      <div className="mt-4">
        {present ? (
          <>
            <FieldRow label="Name" mono>
              {fullName ?? <span className="text-[#C0C0BA]">—</span>}
            </FieldRow>
            <FieldRow label="ID" mono>
              {truncateUuid(info.agentId)}
            </FieldRow>
            <FieldRow label="Voice" empty={!info.voiceId && info.voiceTempStatus !== "match"} mono>
              {info.voiceId ?? (info.voiceTempStatus === "match" ? "matches reference" : null)}
            </FieldRow>
            <FieldRow label="Temperature" empty={!info.temperature && info.voiceTempStatus !== "match"} mono>
              {info.temperature ?? (info.voiceTempStatus === "match" ? "matches reference" : null)}
            </FieldRow>
            <FieldRow label="Prompt size" empty={!info.systemPromptBytes}>
              {info.systemPromptBytes
                ? `${(info.systemPromptBytes / 1024).toFixed(1)} KB`
                : null}
            </FieldRow>
          </>
        ) : (
          <p className="text-[14px] text-[#7A7A72]">
            No Ultravox agent created yet — operator runs <code className="font-mono text-[13px] text-[#1A1A1A]">/base-agent</code> to onboard this customer.
          </p>
        )}
      </div>
    </section>
  );
}
