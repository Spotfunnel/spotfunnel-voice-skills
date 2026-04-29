import { describe, expect, it } from "vitest";
import {
  aggregateStatus,
  extractAgentInfo,
  extractDashboard,
  extractTelephony,
  formatAuPhone,
  maskPhone,
  summariseTool,
  summaryToDot,
  truncateUuid,
} from "@/lib/inspect-extractors";

describe("formatAuPhone", () => {
  it("formats AU landline to +61 X XXXX XXXX", () => {
    expect(formatAuPhone("+61212345678")).toBe("+61 2 1234 5678");
    expect(formatAuPhone("+61272542091")).toBe("+61 2 7254 2091");
  });

  it("formats AU mobile (+614xx) to +61 4XX XXX XXX", () => {
    expect(formatAuPhone("+61412345678")).toBe("+61 412 345 678");
  });

  it("formats AU 13xx specials", () => {
    expect(formatAuPhone("+61130012345")).toBe("+61 1300 12345");
  });

  it("returns null on null/undefined input", () => {
    expect(formatAuPhone(null)).toBeNull();
    expect(formatAuPhone(undefined)).toBeNull();
  });

  it("passes through unrecognized formats unchanged", () => {
    expect(formatAuPhone("+15551234567")).toBe("+15551234567");
  });
});

describe("aggregateStatus", () => {
  const checks = [
    { id: "a", status: "pass" },
    { id: "b", status: "fail" },
    { id: "c", status: "skip" },
    { id: "d", status: "pass" },
  ];

  it("returns 'fail' if any of the matched checks failed", () => {
    expect(aggregateStatus(checks, ["a", "b", "d"])).toBe("fail");
  });

  it("returns 'pass' when all matched checks passed", () => {
    expect(aggregateStatus(checks, ["a", "d"])).toBe("pass");
  });

  it("returns 'skip' when every matched check is skip", () => {
    expect(aggregateStatus(checks, ["c"])).toBe("skip");
  });

  it("returns 'none' when no matched checks exist", () => {
    expect(aggregateStatus(checks, ["nonexistent"])).toBe("none");
  });
});

describe("summaryToDot", () => {
  it("returns 'fail' when any failures present", () => {
    expect(summaryToDot({ pass: 5, fail: 1, skip: 2 })).toBe("fail");
  });

  it("returns 'partial' when there are skips alongside passes", () => {
    expect(summaryToDot({ pass: 5, fail: 0, skip: 2 })).toBe("partial");
  });

  it("returns 'pass' when only passes are present", () => {
    expect(summaryToDot({ pass: 5, fail: 0, skip: 0 })).toBe("pass");
  });

  it("returns 'none' on no data", () => {
    expect(summaryToDot(undefined)).toBe("none");
    expect(summaryToDot({})).toBe("none");
  });
});

describe("extractAgentInfo", () => {
  it("pulls agent_id + first name + customer name from state", () => {
    const info = extractAgentInfo(
      { ultravox_agent_id: "abc-123", agent_first_name: "Mac", customer_name: "Goulburn Transport" },
      [],
    );
    expect(info.agentId).toBe("abc-123");
    expect(info.agentFirstName).toBe("Mac");
    expect(info.customerName).toBe("Goulburn Transport");
  });

  it("extracts system-prompt byte count from check detail", () => {
    const info = extractAgentInfo(null, [
      {
        id: "system-prompt-matches-artifact",
        status: "pass",
        detail: "sizes match (18432 bytes)",
      },
    ]);
    expect(info.systemPromptBytes).toBe(18432);
  });

  it("returns nulls when state + checks are empty", () => {
    const info = extractAgentInfo(null, []);
    expect(info.agentId).toBeNull();
    expect(info.systemPromptBytes).toBeNull();
  });
});

describe("extractTelephony", () => {
  it("formats AU phone number from state.telnyx_did", () => {
    const info = extractTelephony({ telnyx_did: "+61272542091", area_code: "02" }, []);
    expect(info.phone).toBe("+61272542091");
    expect(info.phoneFormatted).toBe("+61 2 7254 2091");
    expect(info.areaCode).toBe("02");
  });

  it("falls back to state.did when telnyx_did absent", () => {
    const info = extractTelephony({ did: "+61412345678" }, []);
    expect(info.phone).toBe("+61412345678");
  });

  it("scrapes voice_url from check detail", () => {
    const info = extractTelephony(null, [
      {
        id: "telnyx-did-active",
        status: "pass",
        detail: "DID +61272542091 active, voice_url=https://app.ultravox.ai/api/agents/abc/telephony_xml",
      },
    ]);
    expect(info.voiceUrl).toBe("https://app.ultravox.ai/api/agents/abc/telephony_xml");
  });
});

describe("extractDashboard", () => {
  it("captures pass/fail status of workspace + user checks", () => {
    const info = extractDashboard([
      {
        id: "supabase-customer-dashboard-workspace-exists",
        status: "pass",
        detail: "workspace teleca · plan inbound · 1 user",
      },
      {
        id: "supabase-customer-dashboard-auth-user-exists",
        status: "fail",
        detail: "no admin user found",
      },
    ]);
    expect(info.workspaceExists).toBe(true);
    expect(info.primaryUserExists).toBe(false);
    expect(info.workspaceDetail).toBe("workspace teleca · plan inbound · 1 user");
    expect(info.primaryUserDetail).toBe("no admin user found");
  });

  it("returns false flags when checks are missing", () => {
    const info = extractDashboard([]);
    expect(info.workspaceExists).toBe(false);
    expect(info.primaryUserExists).toBe(false);
  });
});

describe("summariseTool", () => {
  it("renders transfer destinations as label → formatted phone", () => {
    const out = summariseTool({
      id: "1",
      tool_name: "transfer",
      config: { destinations: [{ label: "primary", phone: "+61412345678" }] },
      ultravox_tool_id: "uvox-1",
      attached_to_agent_id: "agent-1",
    });
    expect(out.prettyName).toBe("Transfer");
    expect(out.displayValue).toBe("primary → +61 412 345 678");
  });

  it("renders take_message as channel → address", () => {
    const out = summariseTool({
      id: "2",
      tool_name: "take_message",
      config: { recipient: { channel: "email", address: "ops@example.com" } },
      ultravox_tool_id: "uvox-2",
      attached_to_agent_id: "agent-1",
    });
    expect(out.prettyName).toBe("Take message");
    expect(out.displayValue).toBe("email → ops@example.com");
  });

  it("renders empty destinations gracefully", () => {
    const out = summariseTool({
      id: "3",
      tool_name: "transfer",
      config: { destinations: [] },
      ultravox_tool_id: null,
      attached_to_agent_id: null,
    });
    expect(out.displayValue).toBe("(no destinations)");
  });

  it("falls back to JSON for unknown tool names", () => {
    const out = summariseTool({
      id: "4",
      tool_name: "send_sms",
      config: { provider: "twilio" },
      ultravox_tool_id: null,
      attached_to_agent_id: null,
    });
    expect(out.prettyName).toBe("send_sms");
    expect(out.displayValue).toBe('{"provider":"twilio"}');
  });
});

describe("truncateUuid", () => {
  it("truncates long UUIDs to first 8 + ellipsis", () => {
    expect(truncateUuid("01d3d0cf-5f9d-4057-a5f2-cb18e5579a40")).toBe("01d3d0cf…");
  });

  it("returns short strings unchanged", () => {
    expect(truncateUuid("short")).toBe("short");
  });

  it("returns em-dash on null/empty", () => {
    expect(truncateUuid(null)).toBe("—");
    expect(truncateUuid("")).toBe("—");
  });
});

describe("maskPhone", () => {
  it("shows only last 4 digits", () => {
    expect(maskPhone("+61212345678")).toBe("•••• 5678");
  });

  it("returns em-dash on null", () => {
    expect(maskPhone(null)).toBe("—");
  });
});
