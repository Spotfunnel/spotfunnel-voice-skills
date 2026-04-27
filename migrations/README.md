# Migrations

Apply in order on the Supabase project hosting the `operator_ui` schema.

| Order | File | What it does |
|---|---|---|
| 1 | `operator_ui_schema.sql` | Creates the `operator_ui` schema + tables + indexes + initial RLS + grants. Run once on a fresh project. |
| 2 | `operator_ui_auth.sql` | M22 — replaces permissive RLS with an allowlist gate (`kye@`, `leo@getspotfunnel.com`), adds `annotations.author_email` (defaulted from JWT), revokes anon access. |

## How to apply

Paste each file into the Supabase SQL editor and run. Both are idempotent — re-running them is safe.

After applying `operator_ui_auth.sql`, also do the manual Supabase dashboard
steps in `INSTALL.md` (enable Email auth provider, set redirect URLs, invite
the two allowlist users).
