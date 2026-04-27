import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { ChapterRow } from "@/components/ChapterRow";
import { RunHistorySwitcher } from "@/components/RunHistorySwitcher";
import { InspectDeploymentLink } from "@/components/InspectDeploymentLink";
import { CommandPaletteHint } from "@/components/CommandPaletteHint";
import { loadRunHistory } from "@/lib/run-history";
import {
  ARTIFACT_ORDER,
  type Customer,
  type Run,
  type VerificationSummary,
} from "@/lib/types";

const TOTAL_STAGES = 11;

function formatRunDate(iso: string): string {
  // Stable across server/client (no locale surprises): "25 Apr 2026".
  const d = new Date(iso);
  const day = d.getUTCDate();
  const month = d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" });
  const year = d.getUTCFullYear();
  return `${day} ${month} ${year}`;
}

export default async function CustomerPage({
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
  if (!customerRow) {
    notFound();
  }
  const customer = customerRow as Customer;

  // Latest run for this customer.
  const { data: runRow, error: runError } = await supabase
    .from("runs")
    .select("id, customer_id, started_at, stage_complete, state, refined_from_run_id")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }
  const run = (runRow ?? null) as Run | null;

  // Run history for the dropdown — same DB query the run-scoped page uses,
  // extracted so both views show identical metadata.
  const runHistory = await loadRunHistory(
    supabase as unknown as Parameters<typeof loadRunHistory>[0],
    customer.id,
  );

  // Artifact roster for the latest run. Pull only the names — content is M5.
  const artifactNames = new Set<string>();
  if (run) {
    const { data: artifactRows, error: artifactError } = await supabase
      .from("artifacts")
      .select("artifact_name")
      .eq("run_id", run.id);
    if (artifactError) {
      throw new Error(`Failed to load artifacts: ${artifactError.message}`);
    }
    for (const row of artifactRows ?? []) {
      artifactNames.add(row.artifact_name as string);
    }
  }

  // Latest verification row (if any) for the latest run — drives the dot.
  let verificationSummary: VerificationSummary | null = null;
  if (run) {
    const { data: vRow, error: vError } = await supabase
      .from("verifications")
      .select("summary")
      .eq("run_id", run.id)
      .order("verified_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (vError) {
      throw new Error(`Failed to load verification: ${vError.message}`);
    }
    if (vRow) {
      verificationSummary = vRow.summary as VerificationSummary;
    }
  }

  const scrapeCount = run?.state?.scrape_pages_count;

  return (
    <main className="min-h-screen px-8 py-20 sm:px-16 sm:py-24 bg-[#FAFAF7] text-[#1A1A1A]">
      <CommandPaletteHint />
      <div className="mx-auto max-w-3xl">
        <header className="mb-16">
          <h1 className="text-[44px] font-semibold tracking-tight leading-none">
            {customer.name}
          </h1>
          <p className="mt-4 font-mono text-[12px] text-[#9A9A92]">
            {customer.slug}
          </p>
          {run ? (
            <p className="mt-6 text-[13px] text-[#7A7A72]">
              Latest run · {formatRunDate(run.started_at)} · stage{" "}
              {run.stage_complete}/{TOTAL_STAGES}
            </p>
          ) : (
            <p className="mt-6 text-[13px] text-[#7A7A72]">No runs yet</p>
          )}
        </header>

        <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
          Read
        </h2>

        <div className="mt-4 divide-y divide-[#E5E5E0]">
          {ARTIFACT_ORDER.map((chapter, i) => {
            const present = artifactNames.has(chapter.artifact);
            return (
              <ChapterRow
                key={chapter.artifact}
                number={i + 1}
                name={chapter.name}
                href={present ? `/c/${customer.slug}/${chapter.artifact}` : null}
                // Annotations are M6+; render "—" until then.
                annotationCount={null}
              />
            );
          })}

          {/* Chapter 7: scraped pages — sourced from run.state, not artifacts. */}
          {typeof scrapeCount === "number" ? (
            <ChapterRow
              number={7}
              name={`Scraped pages (${scrapeCount})`}
              href={`/c/${customer.slug}/scraped-pages`}
              annotationCount={null}
            />
          ) : (
            <ChapterRow
              number={7}
              name="Scraped pages"
              href={null}
              annotationCount={null}
            />
          )}
        </div>

        <InspectDeploymentLink slug={customer.slug} summary={verificationSummary} />

        <RunHistorySwitcher
          slug={customer.slug}
          runs={runHistory}
          activeRunId={run?.id ?? null}
        />
      </div>
    </main>
  );
}
