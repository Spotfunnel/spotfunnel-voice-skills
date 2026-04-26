import { createClient } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

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
      set: () => {},
      remove: () => {},
    },
    db: { schema: "operator_ui" },
  });
}

/**
 * Browser Supabase client. Scoped to the `operator_ui` schema. Safe to import
 * from Client Components.
 */
export const browserSupabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "operator_ui" },
});
