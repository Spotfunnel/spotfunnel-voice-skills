import Link from "next/link";
import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { dotColor, dotHex } from "@/lib/verification";
import type { Customer, VerificationSummary } from "@/lib/types";

// M20 Inspect view stub. Read-only JSON dump of the latest verification row
// for the customer's latest run. Replaced by a structured checklist in v2.

type VerificationRow = {
  id: string;
  run_id: string;
  verified_at: string;
  summary: VerificationSummary;
  checks: unknown;
  created_at: string;
};

export default async function InspectPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const supabase = await getServerSupabase();

  const { data: customerRow, error: customerError } = await supabase
    .from("customers")
    .select("id, slug, name, created_at")
    .eq("slug", slug)
    .maybeSingle();
  if (customerError) {
    throw new Error(`Failed to load customer: ${customerError.message}`);
  }
  if (!customerRow) notFound();
  const customer = customerRow as Customer;

  const { data: runRow, error: runError } = await supabase
    .from("runs")
    .select("id")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }

  let verification: VerificationRow | null = null;
  if (runRow) {
    const { data: vRow, error: vError } = await supabase
      .from("verifications")
      .select("id, run_id, verified_at, summary, checks, created_at")
      .eq("run_id", runRow.id as string)
      .order("verified_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (vError) {
      throw new Error(`Failed to load verification: ${vError.message}`);
    }
    if (vRow) verification = vRow as VerificationRow;
  }

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <div className="max-w-3xl">
        <div className="text-sm text-[#6B6B6B]">
          <Link
            href={`/c/${customer.slug}`}
            className="hover:text-[#1A1A1A] transition-colors"
          >
            &larr; {customer.name}
          </Link>
          <span className="mx-2 text-[#C0C0BA]">&middot;</span>
          <span>Inspect deployment</span>
        </div>

        <h1 className="mt-4 text-3xl font-medium">Inspect deployment</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />

        {verification ? (
          <InspectBody verification={verification} customerSlug={customer.slug} />
        ) : (
          <p
            className="mt-8 text-sm text-[#6B6B6B]"
            data-testid="inspect-empty"
          >
            Not yet verified &middot;{" "}
            <code className="font-mono text-[13px]">
              Run /base-agent verify {customer.slug} to populate this view.
            </code>
          </p>
        )}
      </div>
    </main>
  );
}

function InspectBody({
  verification,
  customerSlug,
}: {
  verification: VerificationRow;
  customerSlug: string;
}) {
  const color = dotColor(verification.summary);
  const payload = {
    summary: verification.summary,
    checks: verification.checks,
    verified_at: verification.verified_at,
  };
  const json = JSON.stringify(payload, null, 2);

  return (
    <div className="mt-6">
      <div className="flex items-center gap-3 text-sm text-[#6B6B6B]">
        <span
          aria-label={`status: ${color}`}
          style={{ color: dotHex(color) }}
          className="leading-none"
          data-testid="inspect-page-dot"
        >
          &bull;
        </span>
        <span>
          verified {new Date(verification.verified_at).toLocaleString()}
        </span>
        <span className="text-[#C0C0BA]">&middot;</span>
        <span className="font-mono text-xs">/c/{customerSlug}/inspect</span>
      </div>

      <pre
        className="mt-6 bg-white border border-[#E5E5E0] rounded-md p-5 text-[12.5px] leading-relaxed font-mono text-[#1A1A1A] overflow-x-auto whitespace-pre"
        data-testid="inspect-json"
      >
        <JsonHighlight json={json} />
      </pre>
    </div>
  );
}

// Minimal regex-based JSON syntax highlighter so the route stays a Server
// Component (no client deps). Tokens: keys (purple-ish), strings (green-ish),
// numbers (blue-ish), bool/null (orange-ish). Matches the warm palette.
function JsonHighlight({ json }: { json: string }) {
  const re =
    /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/g;
  const parts: Array<{ key: string; text: string; color: string | null }> = [];
  let last = 0;
  let i = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(json)) !== null) {
    if (m.index > last) {
      parts.push({
        key: `t${i++}`,
        text: json.slice(last, m.index),
        color: null,
      });
    }
    const tok = m[0];
    let color: string;
    if (/^"/.test(tok)) {
      color = /:\s*$/.test(tok) ? "#7B3F9F" : "#3F8E5C";
    } else if (/true|false|null/.test(tok)) {
      color = "#B8651D";
    } else {
      color = "#2F5BB0";
    }
    parts.push({ key: `t${i++}`, text: tok, color });
    last = m.index + tok.length;
  }
  if (last < json.length) {
    parts.push({ key: `t${i++}`, text: json.slice(last), color: null });
  }
  return (
    <>
      {parts.map((p) =>
        p.color ? (
          <span key={p.key} style={{ color: p.color }}>
            {p.text}
          </span>
        ) : (
          <span key={p.key}>{p.text}</span>
        ),
      )}
    </>
  );
}
