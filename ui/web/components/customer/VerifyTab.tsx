import { CopyCommandButton } from "@/components/CopyCommandButton";
import { dotColor, dotHex } from "@/lib/verification";
import type { VerificationSummary } from "@/lib/types";

// The verification checklist body — moved out of /c/{slug}/inspect's page
// component so it can be rendered both at /c/{slug}/inspect AND as a tab on
// /c/{slug}?tab=verify. Identical visuals to the M24 InspectBody — same
// status icons, copy-remediation buttons, raw-JSON details — just relocated.

export type CheckRow = {
  id?: string;
  title?: string;
  status?: "pass" | "fail" | "skip" | string;
  detail?: string;
  remediation?: string;
  name?: string;
  ms?: number;
};

export type VerificationRow = {
  id: string;
  run_id: string;
  verified_at: string;
  summary: VerificationSummary;
  checks: unknown;
  created_at: string;
};

function CheckRowItem({ check }: { check: CheckRow }) {
  const status = (check.status ?? "skip").toLowerCase();
  const title = check.title ?? check.id ?? check.name ?? "(unnamed check)";
  const detail = check.detail;
  const remediation = check.remediation;

  let icon = "○";
  let iconColor = dotHex("amber");
  let label = "skip";
  if (status === "pass") {
    icon = "✓";
    iconColor = dotHex("green");
    label = "pass";
  } else if (status === "fail") {
    icon = "✗";
    iconColor = dotHex("red");
    label = "fail";
  }

  return (
    <li
      className="px-5 py-4 text-sm"
      data-testid="inspect-check-row"
      data-check-status={status}
    >
      <div className="flex items-start gap-3">
        <span
          className="mt-0.5 leading-none font-mono text-base"
          style={{ color: iconColor }}
          aria-label={label}
        >
          {icon}
        </span>
        <div className="flex-1 min-w-0">
          <div className="font-medium text-[#1A1A1A]">{title}</div>
          {detail ? (
            <div className="mt-1 text-[#6B6B6B] whitespace-pre-wrap break-words">
              {detail}
            </div>
          ) : null}
          {status === "fail" && remediation ? (
            <div className="mt-2 flex items-start gap-2">
              <code className="flex-1 font-mono text-[12.5px] text-[#1A1A1A] bg-[#FAFAF7] border border-[#E5E5E0] rounded px-2 py-1.5 whitespace-pre-wrap break-words">
                {remediation}
              </code>
              <CopyCommandButton command={remediation} label="copy" compact />
            </div>
          ) : null}
        </div>
      </div>
    </li>
  );
}

export function VerifyTabBody({
  verification,
  customerSlug,
}: {
  verification: VerificationRow;
  customerSlug: string;
}) {
  const color = dotColor(verification.summary);
  const checks = Array.isArray(verification.checks)
    ? (verification.checks as CheckRow[])
    : [];
  const payload = {
    summary: verification.summary,
    checks: verification.checks,
    verified_at: verification.verified_at,
  };
  const json = JSON.stringify(payload, null, 2);

  return (
    <div className="mt-2 py-8 border-t border-[#EDECE6]" data-testid="tab-verify">
      <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
        Verification checks
      </h2>
      <div className="mt-3 flex items-center gap-3 text-sm text-[#6B6B6B]">
        <span
          aria-label={`status: ${color}`}
          style={{ color: dotHex(color) }}
          className="leading-none"
          data-testid="inspect-page-dot"
        >
          &bull;
        </span>
        <span>verified {new Date(verification.verified_at).toLocaleString()}</span>
        <span className="text-[#C0C0BA]">&middot;</span>
        <span className="font-mono text-xs">/c/{customerSlug}/inspect</span>
      </div>

      <ul
        className="mt-6 divide-y divide-[#F0F0EC] border border-[#E5E5E0] rounded-md bg-white"
        data-testid="inspect-checks"
      >
        {checks.length === 0 ? (
          <li className="px-5 py-4 text-sm text-[#6B6B6B]">No checks recorded.</li>
        ) : (
          checks.map((c, i) => <CheckRowItem key={c.id ?? c.name ?? i} check={c} />)
        )}
      </ul>

      <details className="mt-8 group" data-testid="inspect-raw-details">
        <summary className="cursor-pointer text-sm text-[#6B6B6B] hover:text-[#1A1A1A] select-none">
          Raw verification data <span className="ml-1">&#9662;</span>
        </summary>
        <pre
          className="mt-3 bg-white border border-[#E5E5E0] rounded-md p-5 text-[12.5px] leading-relaxed font-mono text-[#1A1A1A] overflow-x-auto whitespace-pre"
          data-testid="inspect-json"
        >
          {json}
        </pre>
      </details>
    </div>
  );
}

export function VerifyTabEmpty({ slug }: { slug: string }) {
  const command = `/base-agent verify ${slug}`;
  return (
    <div className="mt-2 py-8 border-t border-[#EDECE6]" data-testid="tab-verify">
      <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
        Verification checks
      </h2>
      <div className="mt-4" data-testid="inspect-empty">
        <p className="text-sm text-[#6B6B6B]">
          Verification hasn&rsquo;t run yet. The next /base-agent onboarding will
          run it automatically. To run it manually now, copy the command:
        </p>
        <div className="mt-4">
          <CopyCommandButton command={command} label="Copy command" />
        </div>
      </div>
    </div>
  );
}
