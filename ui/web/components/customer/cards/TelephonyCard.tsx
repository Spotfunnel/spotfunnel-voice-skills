import {
  aggregateStatus,
  extractTelephony,
  truncateUuid,
  type CheckRow,
  type RunStateLike,
} from "@/lib/inspect-extractors";
import { SectionHeader, type SectionStatus } from "../SectionHeader";
import { FieldRow } from "../FieldRow";
import { CopyCommandButton } from "@/components/CopyCommandButton";

// Telnyx-side card. Phone (formatted), area code, voice_url, TeXML app id,
// status_callback URL. Status dot derives from the four telnyx-related
// verify checks.

export function TelephonyCard({
  state,
  checks,
  slug,
}: {
  state: RunStateLike | null;
  checks: ReadonlyArray<CheckRow>;
  slug: string;
}) {
  const info = extractTelephony(state, checks);
  const status: SectionStatus = aggregateStatus(checks, [
    "telnyx-did-active",
    "telnyx-call-routing-wired",
    "webhook-callback-set",
  ]);

  const claimed = Boolean(info.phone);

  return (
    <section
      className="border-t border-[#EDECE6] py-8"
      data-testid="card-telephony"
    >
      <SectionHeader title="Telephony" status={claimed ? status : "none"} />
      <div className="mt-4">
        {claimed ? (
          <>
            <FieldRow label="Phone" mono>
              {info.phoneFormatted ?? info.phone}
            </FieldRow>
            <FieldRow label="Area code" empty={!info.areaCode} mono>
              {info.areaCode}
            </FieldRow>
            <FieldRow label="TeXML app" empty={!info.texmlAppId} mono>
              {truncateUuid(info.texmlAppId)}
            </FieldRow>
            <FieldRow label="Voice URL" empty={!info.voiceUrl} mono>
              <span className="block truncate" title={info.voiceUrl ?? undefined}>
                {info.voiceUrl}
              </span>
            </FieldRow>
            <FieldRow label="Status callback" empty={!info.statusCallback} mono>
              <span className="block truncate" title={info.statusCallback ?? undefined}>
                {info.statusCallback}
              </span>
            </FieldRow>
          </>
        ) : (
          <div>
            <p className="text-[14px] text-[#7A7A72]">No phone number claimed yet.</p>
            <div className="mt-3">
              <CopyCommandButton command={`/base-agent ${slug}`} label={`Copy /base-agent ${slug}`} />
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
