import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// Mock the Supabase server helper so the route handler thinks an operator is
// signed in. We control which user comes back per-test by re-stubbing the
// underlying getUser implementation between tests.
const getUserMock = vi.fn();
vi.mock("@/lib/supabase-server", () => ({
  getServerSupabase: async () => ({
    auth: { getUser: getUserMock },
  }),
}));

const ALLOWED_EMAIL = "leo@getspotfunnel.com";
const VALID_ATTACHMENT_B64 = Buffer.from("# acme").toString("base64");

function validBody(overrides: Record<string, unknown> = {}) {
  return {
    subject: "Onboarding — Acme",
    body: "Here are the materials.",
    attachment_name: "acme-context.md",
    attachment_b64: VALID_ATTACHMENT_B64,
    ...overrides,
  };
}

function buildRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/api/email-draft", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function n8nOkResponse() {
  return new Response(
    JSON.stringify({
      draft_id: "r-123",
      thread_id: "t-456",
      message_id: "m-789",
      account: ALLOWED_EMAIL,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

describe("POST /api/email-draft", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    process.env.N8N_EMAIL_DRAFT_WEBHOOK_URL =
      "https://n8n.test.local/webhook/abc";
    process.env.N8N_EMAIL_DRAFT_SECRET = "test-secret";
    getUserMock.mockReset();
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });

  afterEach(() => {
    fetchSpy.mockRestore();
  });

  test("forwards subject + body + attachment to n8n with secret and signed-in email, returns draft_id", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });
    fetchSpy.mockResolvedValue(n8nOkResponse());

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json).toMatchObject({
      draft_id: "r-123",
      thread_id: "t-456",
      account: ALLOWED_EMAIL,
    });

    expect(fetchSpy).toHaveBeenCalledOnce();
    const [calledUrl, calledInit] = fetchSpy.mock.calls[0] as [
      string,
      RequestInit,
    ];
    expect(calledUrl).toBe("https://n8n.test.local/webhook/abc");
    const sentBody = JSON.parse((calledInit.body as string) ?? "{}");
    expect(sentBody).toMatchObject({
      secret: "test-secret",
      subject: "Onboarding — Acme",
      body: "Here are the materials.",
      attachment_name: "acme-context.md",
      attachment_b64: VALID_ATTACHMENT_B64,
      requested_by: ALLOWED_EMAIL,
    });
  });

  test("rejects unauthenticated request with 401", async () => {
    getUserMock.mockResolvedValue({ data: { user: null }, error: null });

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(401);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test("rejects user outside the operator allowlist with 403", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u2", email: "stranger@example.com" } },
      error: null,
    });

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(403);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test("returns 400 when the request body is missing required fields", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest({ subject: "only subject" }));

    expect(res.status).toBe(400);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test("returns 400 when attachment_b64 is empty", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(
      buildRequest(validBody({ attachment_b64: "" })),
    );

    expect(res.status).toBe(400);
    const json = await res.json();
    expect(json.error).toBe("attachment_required");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test("returns 502 when n8n responds with non-2xx", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });
    fetchSpy.mockResolvedValue(
      new Response("upstream boom", { status: 500 }),
    );

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(502);
  });

  test("returns 502 when n8n responds 200 with empty body (validate-throw quirk)", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });
    fetchSpy.mockResolvedValue(new Response("", { status: 200 }));

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(502);
    const json = await res.json();
    expect(json.error).toBe("upstream_invalid_response");
  });

  test("returns 502 when n8n response is missing thread_id or account", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ draft_id: "r-1" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(502);
    const json = await res.json();
    expect(json.error).toBe("upstream_missing_fields");
  });

  test("returns 504 when n8n fetch times out", async () => {
    getUserMock.mockResolvedValue({
      data: { user: { id: "u1", email: ALLOWED_EMAIL } },
      error: null,
    });
    fetchSpy.mockRejectedValue(
      new DOMException("The operation timed out.", "TimeoutError"),
    );

    const { POST } = await import("@/app/api/email-draft/route");
    const res = await POST(buildRequest(validBody()));

    expect(res.status).toBe(504);
    const json = await res.json();
    expect(json.error).toBe("upstream_timeout");
  });
});
