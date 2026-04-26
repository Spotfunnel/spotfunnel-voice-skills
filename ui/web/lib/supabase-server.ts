import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

const SUPABASE_URL = required("NEXT_PUBLIC_SUPABASE_URL");
const SUPABASE_ANON_KEY = required("NEXT_PUBLIC_SUPABASE_ANON_KEY");

// Sanity check URL shape so placeholder strings fail at boot instead of at first query
try {
  new URL(SUPABASE_URL);
} catch {
  throw new Error(`NEXT_PUBLIC_SUPABASE_URL is not a valid URL: ${SUPABASE_URL}`);
}

/**
 * Server-side Supabase client for use in Server Components, Route Handlers,
 * and Server Actions. Scoped to the `operator_ui` schema.
 *
 * Next.js 15 made `cookies()` async, so this helper is async too. Callers
 * must `await getServerSupabase()`.
 */
export async function getServerSupabase() {
  const cookieStore = await cookies();
  return createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      get: (n: string) => cookieStore.get(n)?.value,
      // No-op: auth lives at the Vercel layer (password protection), not in
      // Supabase, so we never write Supabase auth cookies. If Supabase Auth
      // is ever wired in, replace with cookieStore.set / cookieStore.delete.
      set: () => {},
      remove: () => {},
    },
    db: { schema: "operator_ui" },
  });
}
