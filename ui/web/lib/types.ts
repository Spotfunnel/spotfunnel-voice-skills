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
  // jsonb — shape varies per pipeline stage. Only fields the UI reads are
  // typed; everything else stays unknown so we don't lie about presence.
  state: {
    customer_name?: string;
    slug?: string;
    scrape_pages_count?: number;
    [key: string]: unknown;
  };
};
