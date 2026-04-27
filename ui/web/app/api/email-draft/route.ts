import { NextResponse } from "next/server";
import { getServerSupabase } from "@/lib/supabase-server";

const ALLOWLIST = ["leo@getspotfunnel.com", "kye@getspotfunnel.com"];

type DraftBody = {
  subject?: unknown;
  body?: unknown;
  attachment_name?: unknown;
  attachment_b64?: unknown;
};

function isString(v: unknown): v is string {
  return typeof v === "string";
}

export async function POST(req: Request): Promise<Response> {
  const webhookUrl = process.env.N8N_EMAIL_DRAFT_WEBHOOK_URL;
  const secret = process.env.N8N_EMAIL_DRAFT_SECRET;
  if (!webhookUrl || !secret) {
    return NextResponse.json(
      { error: "server_misconfigured" },
      { status: 500 },
    );
  }

  const supabase = await getServerSupabase();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data?.user?.email) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const email = data.user.email.toLowerCase();
  if (!ALLOWLIST.includes(email)) {
    return NextResponse.json({ error: "forbidden" }, { status: 403 });
  }

  let parsed: DraftBody;
  try {
    parsed = (await req.json()) as DraftBody;
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }
  if (
    !isString(parsed.subject) ||
    !isString(parsed.body) ||
    !isString(parsed.attachment_name) ||
    !isString(parsed.attachment_b64)
  ) {
    return NextResponse.json({ error: "invalid_body" }, { status: 400 });
  }
  // Empty attachment_b64 surfaces from n8n as an opaque "binary property not
  // found" error inside the Gmail node. Reject it here so the operator gets a
  // clear 400 instead of a 502 that hides the real cause.
  if (parsed.attachment_b64.length === 0 || parsed.attachment_name.length === 0) {
    return NextResponse.json(
      { error: "attachment_required" },
      { status: 400 },
    );
  }

  let upstream: Response;
  try {
    upstream = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        secret,
        subject: parsed.subject,
        body: parsed.body,
        attachment_name: parsed.attachment_name,
        attachment_b64: parsed.attachment_b64,
        requested_by: email,
      }),
      // 8s caps the worst-case latency a hung n8n can impose on the operator
      // before they see a clean error. Vercel's serverless slot would
      // otherwise idle until the function-level timeout (10s Hobby / 60s Pro).
      signal: AbortSignal.timeout(8_000),
    });
  } catch (err) {
    const isAbort =
      err instanceof DOMException && err.name === "TimeoutError";
    return NextResponse.json(
      { error: isAbort ? "upstream_timeout" : "upstream_unreachable" },
      { status: 504 },
    );
  }

  if (!upstream.ok) {
    return NextResponse.json(
      { error: "upstream_failed", status: upstream.status },
      { status: 502 },
    );
  }

  // n8n quirk: when a node throws (e.g. our Validate code rejecting an email
  // not in the allowlist), the webhook still returns 200 with an empty body
  // because the Respond node never fires. Treat that — and any other
  // malformed response — as an upstream failure instead of cascading a 500
  // out of `await upstream.json()`.
  let upstreamJson: { thread_id?: unknown; message_id?: unknown; account?: unknown };
  try {
    upstreamJson = await upstream.json();
  } catch {
    return NextResponse.json(
      { error: "upstream_invalid_response" },
      { status: 502 },
    );
  }
  const threadId =
    isString(upstreamJson.thread_id) && upstreamJson.thread_id.length > 0
      ? upstreamJson.thread_id
      : isString(upstreamJson.message_id) && upstreamJson.message_id.length > 0
        ? upstreamJson.message_id
        : null;
  const account =
    isString(upstreamJson.account) && upstreamJson.account.length > 0
      ? upstreamJson.account
      : null;
  if (!threadId || !account) {
    return NextResponse.json(
      { error: "upstream_missing_fields" },
      { status: 502 },
    );
  }
  return NextResponse.json(upstreamJson, { status: 200 });
}
