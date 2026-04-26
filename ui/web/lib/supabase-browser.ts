"use client";
import { createClient } from "@supabase/supabase-js";

// Lazy singleton: env-var check + createClient only run on first use, never
// at module-load time. This avoids tripping the env-var assertion during the
// server-side render pass of any Server Component that transitively imports
// a Client Component which imports this module — Next.js inlines NEXT_PUBLIC_
// vars in the client bundle, but the module is also evaluated server-side
// during SSR, where direct `process.env` reads can be unreliable from inside
// a "use client" file.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _client: any = null;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getClient(): any {
  if (_client) return _client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url) throw new Error("Missing env var: NEXT_PUBLIC_SUPABASE_URL");
  if (!key) throw new Error("Missing env var: NEXT_PUBLIC_SUPABASE_ANON_KEY");
  _client = createClient(url, key, {
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
