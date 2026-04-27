// Shared types for operator_ui pages + components.
// Mirrors the columns selected from operator_ui.* tables — keep narrow on
// purpose so each page only fetches what it renders.

export type Customer = {
  id: string;
  slug: string;
  name: string;
  created_at: string;
};

export type Run = {
  id: string;
  customer_id: string;
  started_at: string;
  stage_complete: number;
  // M12: when a refine is launched off a prior run, the new run row keeps
  // the source run id here so the UI can show the lineage.
  refined_from_run_id?: string | null;
  // jsonb — shape varies per pipeline stage. Only fields the UI reads are
  // typed; everything else stays unknown so we don't lie about presence.
  state: {
    customer_name?: string;
    slug?: string;
    scrape_pages_count?: number;
    [key: string]: unknown;
  };
};

// Mirrors operator_ui.verifications. summary is the {pass, fail, skip} jsonb;
// checks is the per-check array. Inspect view (M20) reads only the latest
// row per run.
export type VerificationSummary = {
  pass?: number;
  fail?: number;
  skip?: number;
  [key: string]: unknown;
};

export type Verification = {
  id: string;
  run_id: string;
  verified_at: string;
  summary: VerificationSummary;
  checks: unknown;
  created_at: string;
};

export type Artifact = {
  artifact_name: string;
  content: string;
};

// Mirrors operator_ui.annotations. Includes anchor fields (quote/prefix/suffix
// + char offsets) — three-strategy anchor so highlights can survive content
// edits between runs (M7+ orphan recovery; M6 just renders by char offset).
export type Annotation = {
  id: string;
  run_id: string;
  artifact_name: string;
  quote: string;
  prefix: string;
  suffix: string;
  char_start: number;
  char_end: number;
  comment: string;
  status: "open" | "resolved" | "orphan" | "deleted";
  author_name: string;
  created_at: string;
  resolved_by_run_id: string | null;
  resolved_classification: "per-run" | "feedback" | null;
};

// Canonical chapter order for the 6 artifact-backed slots. Index drives
// chapter numbering on the customer page (M4) and "Next:" footer logic on
// the reading-mode page (M5). `scraped-pages` is intentionally NOT here —
// it's chapter 7, sourced from run.state, and handled separately.
export const ARTIFACT_ORDER: ReadonlyArray<{ name: string; artifact: string }> = [
  { name: "Brain doc", artifact: "brain-doc" },
  { name: "System prompt", artifact: "system-prompt" },
  { name: "Discovery prompt", artifact: "discovery-prompt" },
  { name: "Customer context", artifact: "customer-context" },
  { name: "Cover email", artifact: "cover-email" },
  { name: "Meeting transcript", artifact: "meeting-transcript" },
];

// Slug allowlist derived from ARTIFACT_ORDER — kept as a Set for O(1) checks
// in the reading-mode route.
export const ARTIFACT_SLUGS: ReadonlySet<string> = new Set(
  ARTIFACT_ORDER.map((c) => c.artifact),
);
