import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { ChapterRow } from "@/components/ChapterRow";
import type { Customer, Run } from "@/lib/types";

// Fixed chapter order. Index 0..5 correspond to artifact_name rows;
// index 6 is the special scraped-pages chapter that reads from run.state.
const CHAPTERS: Array<{ name: string; artifact: string }> = [
  { name: "Brain doc", artifact: "brain-doc" },
  { name: "System prompt", artifact: "system-prompt" },
  { name: "Discovery prompt", artifact: "discovery-prompt" },
  { name: "Customer context", artifact: "customer-context" },
  { name: "Cover email", artifact: "cover-email" },
  { name: "Meeting transcript", artifact: "meeting-transcript" },
];

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
    .select("id, customer_id, started_at, stage_complete, state")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }
  const run = (runRow ?? null) as Run | null;

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

  const scrapeCount = run?.state?.scrape_pages_count;

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <div className="max-w-2xl">
        <h1 className="text-3xl font-medium">{customer.name}</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        {run ? (
          <p className="mt-4 text-sm text-[#6B6B6B]">
            Latest run · {formatRunDate(run.started_at)} · stage {run.stage_complete}/{TOTAL_STAGES}
          </p>
        ) : (
          <p className="mt-4 text-sm text-[#6B6B6B]">No runs yet</p>
        )}

        <h2 className="mt-12 text-xs uppercase tracking-widest text-[#6B6B6B]">
          Read
        </h2>

        <div className="mt-4 divide-y divide-[#E5E5E0]">
          {CHAPTERS.map((chapter, i) => {
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

        <div className="mt-12 flex items-center gap-4 text-sm text-[#6B6B6B]">
          <span>[ Inspect deployment ]</span>
          <span aria-hidden className="text-[#C0C0BA]">●</span>
        </div>

        <div className="mt-2 text-sm text-[#6B6B6B]">Run history ▾</div>
      </div>
    </main>
  );
}
