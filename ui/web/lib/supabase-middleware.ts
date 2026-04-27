import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

// Cookie-refresh helper for Next.js middleware. Mints a server client backed
// by the request's cookie jar, calls supabase.auth.getUser() (which silently
// rotates the session if it's expired), and forwards refreshed cookies onto
// the response so subsequent SSR/route handlers see the new session.
//
// Returns { supabaseResponse, user }. Caller decides whether to redirect.
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    // Fail-open at the middleware layer: pages that actually need auth will
    // throw at render. Surfacing this at every request is noisy.
    return { supabaseResponse, user: null as null };
  }

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        supabaseResponse = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          supabaseResponse.cookies.set(name, value, options);
        }
      },
    },
    db: { schema: "operator_ui" },
  });

  // IMPORTANT: do not run any code between createServerClient and getUser
  // — Supabase docs warn the cookie writes need to land in supabaseResponse.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return { supabaseResponse, user };
}
