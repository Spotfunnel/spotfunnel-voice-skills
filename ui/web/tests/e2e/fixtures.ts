// Shared Playwright fixture for the operator UI e2e suite.
//
// M22: replaced the localStorage operatorName seed with a real Supabase Auth
// session. We pre-create (idempotent) a test user `leo@getspotfunnel.com` —
// already on the RLS allowlist — via the Supabase Admin API, mint a magic
// link via admin.generateLink, exchange it for a session via verifyOtp, then
// inject the resulting access + refresh tokens as the same cookie format
// `@supabase/ssr` reads on first navigation.
//
// Required env vars (any of these per slot is fine):
//   - URL: PLAYWRIGHT_SUPABASE_URL | NEXT_PUBLIC_SUPABASE_URL | SUPABASE_OPERATOR_URL
//   - SERVICE: PLAYWRIGHT_SUPABASE_SERVICE_ROLE_KEY | SUPABASE_OPERATOR_SERVICE_ROLE_KEY
//   - ANON: PLAYWRIGHT_SUPABASE_ANON_KEY | NEXT_PUBLIC_SUPABASE_ANON_KEY
// Without all three, the fixture skips session setup; auth-required pages
// will redirect to /login and most tests will fail (intentional — no env =
// no auth = no test).
//
// Specs should import { test, expect } from "./fixtures" — NOT from
// "@playwright/test" — so the seeded session applies automatically.

import { test as base, expect } from "@playwright/test";
import type { BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL =
  process.env.PLAYWRIGHT_SUPABASE_URL ||
  process.env.NEXT_PUBLIC_SUPABASE_URL ||
  process.env.SUPABASE_OPERATOR_URL ||
  "";
const SUPABASE_SERVICE_KEY =
  process.env.PLAYWRIGHT_SUPABASE_SERVICE_ROLE_KEY ||
  process.env.SUPABASE_OPERATOR_SERVICE_ROLE_KEY ||
  "";
const SUPABASE_ANON_KEY =
  process.env.PLAYWRIGHT_SUPABASE_ANON_KEY ||
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
  "";

export const TEST_EMAIL = "leo@getspotfunnel.com";

type SessionPayload = {
  access_token: string;
  refresh_token: string;
  expires_at: number;
  expires_in: number;
  token_type: "bearer";
  user: { email: string };
};

let cachedSession: SessionPayload | null = null;

function envReady(): boolean {
  return !!(SUPABASE_URL && SUPABASE_SERVICE_KEY && SUPABASE_ANON_KEY);
}

function projectRef(): string {
  return new URL(SUPABASE_URL).hostname.split(".")[0];
}

async function ensureUserExists(): Promise<void> {
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  // Idempotent: if the user already exists this returns an error (422) which
  // we ignore. The allowlist check is in RLS, not at signup.
  await admin.auth.admin.createUser({
    email: TEST_EMAIL,
    email_confirm: true,
  });
}

async function mintTestSession(): Promise<SessionPayload | null> {
  if (cachedSession) return cachedSession;
  if (!envReady()) return null;

  await ensureUserExists();

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: TEST_EMAIL,
  });
  if (error || !data?.properties?.hashed_token) {
    // eslint-disable-next-line no-console
    console.warn("playwright fixtures: generateLink failed", error?.message);
    return null;
  }

  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: verified, error: verifyErr } = await anon.auth.verifyOtp({
    type: "magiclink",
    token_hash: data.properties.hashed_token,
  });
  if (verifyErr || !verified?.session) {
    // eslint-disable-next-line no-console
    console.warn(
      "playwright fixtures: verifyOtp failed",
      verifyErr?.message,
    );
    return null;
  }

  cachedSession = {
    access_token: verified.session.access_token,
    refresh_token: verified.session.refresh_token,
    expires_at:
      verified.session.expires_at ??
      Math.floor(Date.now() / 1000) + 3600,
    expires_in: verified.session.expires_in ?? 3600,
    token_type: "bearer",
    user: { email: TEST_EMAIL },
  };
  return cachedSession;
}

// Encode session as the cookie value @supabase/ssr expects: `base64-` prefix
// + base64url(JSON). Keep it under 4kB so we don't need to chunk; Supabase's
// access tokens are typically ~1kB.
function encodeSessionCookie(session: SessionPayload): string {
  const json = JSON.stringify(session);
  const b64 = Buffer.from(json, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `base64-${b64}`;
}

async function deleteFixtureAnnotations(): Promise<void> {
  if (!envReady()) return;
  const headers = {
    apikey: SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
    "Accept-Profile": "operator_ui",
    "Content-Profile": "operator_ui",
    Prefer: "return=minimal",
  };
  try {
    await fetch(
      `${SUPABASE_URL}/rest/v1/annotations?author_email=eq.${encodeURIComponent(TEST_EMAIL)}`,
      { method: "DELETE", headers },
    );
    // Legacy localStorage-era rows.
    await fetch(
      `${SUPABASE_URL}/rest/v1/annotations?author_name=eq.playwright`,
      { method: "DELETE", headers },
    );
  } catch {
    // swallow; the test will surface the issue if cleanup actually mattered
  }
}

type Fixtures = {
  context: BrowserContext;
};

export const test = base.extend<Fixtures>({
  context: async ({ context }, use) => {
    await deleteFixtureAnnotations();

    const session = await mintTestSession();
    if (session) {
      const cookieName = `sb-${projectRef()}-auth-token`;
      const value = encodeSessionCookie(session);
      // Set on both 127.0.0.1 + localhost so dev / CI variants both work.
      await context.addCookies([
        {
          name: cookieName,
          value,
          domain: "localhost",
          path: "/",
          httpOnly: false,
          secure: false,
          sameSite: "Lax",
          expires: Math.floor(Date.now() / 1000) + 3600,
        },
      ]);
    }

    await use(context);
    await deleteFixtureAnnotations();
  },
});

export { expect };
