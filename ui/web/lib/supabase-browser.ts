"use client";
import { createBrowserClient } from "@supabase/ssr";

// Lazy singleton: env-var check + createBrowserClient only run on first use,
// never at module-load time. This avoids tripping the env-var assertion during
// the server-side render pass of any Server Component that transitively imports
// a Client Component which imports this module.
//
// Auth cookies set by createBrowserClient are read by the SSR server client +
// the Next middleware, so a magic-link sign-in in the browser propagates to
// every server-rendered route on the next navigation.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _client: any = null;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getClient(): any {
  if (_client) return _client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url) throw new Error("Missing env var: NEXT_PUBLIC_SUPABASE_URL");
  if (!key) throw new Error("Missing env var: NEXT_PUBLIC_SUPABASE_ANON_KEY");
  _client = createBrowserClient(url, key, {
    db: { schema: "operator_ui" },
  });
  return _client;
}

// Proxy preserves the existing import shape: `import { browserSupabase }` and
// then `browserSupabase.from(...)` keeps working, but the underlying client
// is only instantiated on first method access.
export const browserSupabase = new Proxy(
  {},
  {
    get(_target, prop) {
      const c = getClient();
      const value = c[prop];
      return typeof value === "function" ? value.bind(c) : value;
    },
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
) as any;
