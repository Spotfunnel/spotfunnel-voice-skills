import Link from "next/link";
import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { ChapterRow } from "@/components/ChapterRow";
import { RunHistorySwitcher } from "@/components/RunHistorySwitcher";
import { InspectDeploymentLink } from "@/components/InspectDeploymentLink";
import { loadRunHistory, validateRunId } from "@/lib/run-history";
import {
  ARTIFACT_ORDER,
  type Customer,
  type Run,
  type VerificationSummary,
} from "@/lib/types";

const TOTAL_STAGES = 11;

function formatRunDate(iso: string): string {
  const d = new Date(iso);
  const day = d.getUTCDate();
  const month = d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" });
  const year = d.getUTCFullYear();
  return `${day} ${month} ${year}`;
}

// Run-scoped customer page (M18). Same chapter roster as /c/{slug} but for a
// specific run id, so operators can browse refine ancestors without losing
// the per-run annotations + artifacts.
export default async function RunScopedCustomerPage({
  params,
}: {
  params: Promise<{ slug: string; runId: string }>;
}) {
  const { slug, runId } = await params;
  // Reject malformed run ids before they hit Postgrest (which would 400
  // with "invalid input syntax for type uuid" and surface as a 500).
  if (!validateRunId(runId)) notFound();
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
    .select("id, customer_id, started_at, stage_complete, state, refined_from_run_id")
    .eq("id", runId)
    .eq("customer_id", customer.id)
    .maybeSingle();
  if (runError) {
    throw new Error(`Failed to load run: ${runError.message}`);
  }
  if (!runRow) notFound();
  const run = runRow as Run;

  const runHistory = await loadRunHistory(
    supabase as unknown as Parameters<typeof loadRunHistory>[0],
    customer.id,
  );

  const artifactNames = new Set<string>();
  const openByArtifact = new Map<string, number>();
  const resolvedByArtifact = new Map<string, number>();
  const [artifactRows, annotationRows] = await Promise.all([
    supabase
      .from("artifacts")
      .select("artifact_name")
      .eq("run_id", run.id),
    supabase
      .from("annotations")
      .select("artifact_name, status")
      .eq("run_id", run.id)
      .in("status", ["open", "resolved"]),
  ]);
  if (artifactRows.error) {
    throw new Error(`Failed to load artifacts: ${artifactRows.error.message}`);
  }
  if (annotationRows.error) {
    throw new Error(
      `Failed to load annotation counts: ${annotationRows.error.message}`,
    );
  }
  for (const row of artifactRows.data ?? []) {
    artifactNames.add(row.artifact_name as string);
  }
  for (const row of annotationRows.data ?? []) {
    const name = row.artifact_name as string;
    const status = row.status as string;
    const target = status === "open" ? openByArtifact : resolvedByArtifact;
    target.set(name, (target.get(name) ?? 0) + 1);
  }

  let verificationSummary: VerificationSummary | null = null;
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
  if (vRow) verificationSummary = vRow.summary as VerificationSummary;

  const scrapeCount = run.state?.scrape_pages_count;
  const isLatest = runHistory[0]?.id === run.id;

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <div className="max-w-2xl">
        <div className="text-sm text-[#6B6B6B]">
          <Link
            href={`/c/${customer.slug}`}
            className="hover:text-[#1A1A1A] transition-colors"
          >
            ← {customer.name}
          </Link>
        </div>
        <h1 className="mt-4 text-3xl font-medium">{customer.name}</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        <p className="mt-4 text-sm text-[#6B6B6B]" data-testid="run-scope-banner">
          {isLatest ? "Latest run" : "Historical run"} ·{" "}
          {formatRunDate(run.started_at)} · stage {run.stage_complete}/{TOTAL_STAGES}
        </p>

        <h2 className="mt-12 text-xs uppercase tracking-widest text-[#6B6B6B]">
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
                href={
                  present
                    ? `/c/${customer.slug}/run/${run.id}/${chapter.artifact}`
                    : null
                }
                openCount={openByArtifact.get(chapter.artifact) ?? 0}
                resolvedCount={resolvedByArtifact.get(chapter.artifact) ?? 0}
              />
            );
          })}

          {typeof scrapeCount === "number" ? (
            <ChapterRow
              number={7}
              name={`Scraped pages (${scrapeCount})`}
              // No run-scoped scraped-pages route yet; fall back to latest.
              href={`/c/${customer.slug}/scraped-pages`}
              openCount={openByArtifact.get("scraped-pages") ?? 0}
              resolvedCount={resolvedByArtifact.get("scraped-pages") ?? 0}
            />
          ) : (
            <ChapterRow
              number={7}
              name="Scraped pages"
              href={null}
              openCount={null}
              resolvedCount={null}
            />
          )}
        </div>

        <InspectDeploymentLink slug={customer.slug} summary={verificationSummary} />

        <RunHistorySwitcher
          slug={customer.slug}
          runs={runHistory}
          activeRunId={run.id}
        />
      </div>
    </main>
  );
}
