import Link from "next/link";
import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { ArtifactReader } from "@/components/ArtifactReader";
import {
  ARTIFACT_ORDER,
  ARTIFACT_SLUGS,
  type Annotation,
  type Customer,
  type Run,
} from "@/lib/types";

// Server Component. Fetches data + chrome; embeds <ArtifactReader> for the
// interactive markdown body (selection capture + annotation save). M6 keeps
// the SSR-rendered shell so the page works without JS — the client component
// only takes over the body once hydrated.

export default async function ArtifactPage({
  params,
}: {
  params: Promise<{ slug: string; artifact: string }>;
}) {
  const { slug, artifact } = await params;

  // Allowlist gate: anything outside the 6-slot order 404s without a query.
  // `scraped-pages` is intentionally excluded — it has bespoke handling
  // deferred to a later milestone.
  if (!ARTIFACT_SLUGS.has(artifact)) {
    notFound();
  }

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

  // Narrow select: state isn't read on this page (see M4 review note).
  const { data: runRow, error: runError } = await supabase
    .from("runs")
    .select("id, customer_id, started_at, stage_complete")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }
  if (!runRow) {
    notFound();
  }
  const run = runRow as Pick<Run, "id" | "customer_id" | "started_at" | "stage_complete">;

  // Fetch artifact + roster + annotations in parallel — all share `run_id`
  // and don't depend on each other. Annotations are filtered to live states
  // (open/orphan); resolved/deleted are excluded from the rendered overlay.
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
      .in("status", ["open", "orphan"])
      .order("char_start", { ascending: true }),
  ]);

  if (artifactRes.error) {
    throw new Error(`Failed to load artifact: ${artifactRes.error.message}`);
  }
  if (!artifactRes.data) {
    notFound();
  }
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

  // Find the current chapter via name lookup (allowlist guarantees it exists).
  const currentChapter = ARTIFACT_ORDER.find((c) => c.artifact === artifact);
  if (!currentChapter) notFound(); // unreachable given allowlist; satisfies TS.
  const currentIndex = ARTIFACT_ORDER.indexOf(currentChapter);

  // Footer semantics: link to the next chapter that ACTUALLY has an artifact
  // row, not the next slot in ARTIFACT_ORDER. So if a customer has only
  // brain-doc + discovery-prompt (system-prompt missing), brain-doc's footer
  // points at discovery-prompt rather than dead-linking to a 404.
  const nextChapter =
    ARTIFACT_ORDER.slice(currentIndex + 1).find((c) =>
      presentNames.has(c.artifact),
    ) ?? null;

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A] relative">
      {/* Top bar */}
      <div className="max-w-3xl mx-auto text-sm text-[#6B6B6B]">
        <Link
          href={`/c/${customer.slug}`}
          className="hover:text-[#1A1A1A] transition-colors"
        >
          ← {customer.name}
        </Link>
        <span className="mx-2 text-[#C0C0BA]">·</span>
        <span>{currentChapter.name}</span>
      </div>

      {/* Body — interactive (selection + annotation overlay) */}
      <ArtifactReader
        content={content}
        runId={run.id}
        artifactName={artifact}
        annotations={annotations}
      />

      {/* Footer: only when a later chapter exists with an artifact row */}
      {nextChapter ? (
        <div className="max-w-3xl mx-auto mt-16 text-sm">
          <Link
            href={`/c/${customer.slug}/${nextChapter.artifact}`}
            className="text-[#6B6B6B] hover:text-[#1A1A1A] transition-colors"
          >
            Next: {nextChapter.name} →
          </Link>
        </div>
      ) : null}
    </main>
  );
}
