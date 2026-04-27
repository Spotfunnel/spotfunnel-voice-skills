import Link from "next/link";
import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { validateRunId } from "@/lib/run-history";
import { ArtifactReader } from "@/components/ArtifactReader";
import {
  ARTIFACT_ORDER,
  ARTIFACT_SLUGS,
  type Annotation,
  type Customer,
  type Run,
} from "@/lib/types";

// Run-scoped reading mode (M18). Mirrors /c/[slug]/[artifact]/page.tsx but
// pinned to a specific run id so historical runs are browsable. Annotations
// are scoped by run_id, which is exactly what the existing FK already
// enforces — nothing else changes.

export default async function RunScopedArtifactPage({
  params,
}: {
  params: Promise<{ slug: string; runId: string; artifact: string }>;
}) {
  const { slug, runId, artifact } = await params;

  if (!ARTIFACT_SLUGS.has(artifact)) {
    notFound();
  }
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
    .select("id, customer_id, started_at, stage_complete")
    .eq("id", runId)
    .eq("customer_id", customer.id)
    .maybeSingle();
  if (runError) {
    throw new Error(`Failed to load run: ${runError.message}`);
  }
  if (!runRow) notFound();
  const run = runRow as Pick<Run, "id" | "customer_id" | "started_at" | "stage_complete">;

  const [artifactRes, rosterRes, annotationsRes] = await Promise.all([
    supabase
      .from("artifacts")
      .select("artifact_name, content")
      .eq("run_id", run.id)
      .eq("artifact_name", artifact)
      .maybeSingle(),
    supabase
      .from("artifacts")
      .select("artifact_name")
      .eq("run_id", run.id),
    supabase
      .from("annotations")
      .select(
        "id, run_id, artifact_name, quote, prefix, suffix, char_start, char_end, comment, status, author_name, created_at, resolved_by_run_id, resolved_classification",
      )
      .eq("run_id", run.id)
      .eq("artifact_name", artifact)
      .order("char_start", { ascending: true }),
  ]);

  if (artifactRes.error) {
    throw new Error(`Failed to load artifact: ${artifactRes.error.message}`);
  }
  if (!artifactRes.data) notFound();
  const content = artifactRes.data.content as string;

  if (rosterRes.error) {
    throw new Error(`Failed to load artifact roster: ${rosterRes.error.message}`);
  }
  const presentNames = new Set<string>(
    (rosterRes.data ?? []).map((r) => r.artifact_name as string),
  );

  if (annotationsRes.error) {
    throw new Error(`Failed to load annotations: ${annotationsRes.error.message}`);
  }
  const annotations = (annotationsRes.data ?? []) as Annotation[];

  const currentChapter = ARTIFACT_ORDER.find((c) => c.artifact === artifact);
  if (!currentChapter) notFound();
  const currentIndex = ARTIFACT_ORDER.indexOf(currentChapter);

  const nextChapter =
    ARTIFACT_ORDER.slice(currentIndex + 1).find((c) =>
      presentNames.has(c.artifact),
    ) ?? null;

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A] relative">
      <div className="max-w-3xl mx-auto text-sm text-[#6B6B6B]">
        <Link
          href={`/c/${customer.slug}/run/${run.id}`}
          className="hover:text-[#1A1A1A] transition-colors"
        >
          ← {customer.name}
        </Link>
        <span className="mx-2 text-[#C0C0BA]">·</span>
        <span>{currentChapter.name}</span>
        <span className="mx-2 text-[#C0C0BA]">·</span>
        <span>historical run</span>
      </div>

      <ArtifactReader
        content={content}
        runId={run.id}
        artifactName={artifact}
        chapterName={currentChapter.name}
        annotations={annotations}
      />

      {nextChapter ? (
        <div className="max-w-3xl mx-auto mt-16 text-sm">
          <Link
            href={`/c/${customer.slug}/run/${run.id}/${nextChapter.artifact}`}
            className="text-[#6B6B6B] hover:text-[#1A1A1A] transition-colors"
          >
            Next: {nextChapter.name} →
          </Link>
        </div>
      ) : null}
    </main>
  );
}
