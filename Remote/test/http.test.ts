import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type {
  CallToolResult,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { describe, expect, it } from "bun:test";
import type { MCPBackend } from "../src/backend.js";
import type { GatewayConfig } from "../src/config.js";
import { startHttpServer } from "../src/http.js";

const TOKEN = "0123456789abcdef0123456789abcdef";

class FakeBackend implements MCPBackend {
  private readonly tools: Tool[] = [
    {
      name: "mail_server_info",
      description: "Return non-sensitive server and adapter diagnostics.",
      inputSchema: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false,
      },
    },
  ];

  public calls: string[] = [];
  public listSignals: AbortSignal[] = [];
  public callSignals: AbortSignal[] = [];
  public pings = 0;

  public async start(): Promise<void> {}

  public async listTools(signal?: AbortSignal): Promise<Tool[]> {
    if (signal) this.listSignals.push(signal);
    return this.tools;
  }

  public async callTool(name: string, _args?: Record<string, unknown>, signal?: AbortSignal): Promise<CallToolResult> {
    this.calls.push(name);
    if (signal) this.callSignals.push(signal);
    return {
      content: [{ type: "text", text: JSON.stringify({ success: true, data: { name } }) }],
      structuredContent: { success: true, data: { name } },
      isError: false,
    };
  }

  public async ping(): Promise<void> {
    this.pings += 1;
  }

  public async close(): Promise<void> {}
}

function tokenConfig(overrides: Partial<GatewayConfig> = {}): GatewayConfig {
  return {
    backend: {
      kind: "stdio",
      executable: "/unused-in-test",
      args: [],
    },
    host: "127.0.0.1",
    port: 0,
    endpointPath: "/mail",
    requestTimeoutMs: 60_000,
    allowedOrigins: [],
    auth: { kind: "token", token: TOKEN },
    ...overrides,
  };
}

describe("remote Streamable HTTP gateway", () => {
  it("proxies MCP discovery and tool calls over a token-protected endpoint", async () => {
    const backend = new FakeBackend();
    const running = await startHttpServer(tokenConfig(), backend);
    try {
      const health = await fetch(new URL("/healthz", running.origin));
      expect(health.status).toBe(200);
      expect(await health.json()).toEqual({ status: "ok" });

      const ready = await fetch(new URL("/readyz", running.origin));
      expect(ready.status).toBe(200);
      expect(await ready.json()).toEqual({ status: "ready" });
      expect(backend.pings).toBe(1);

      const wrongPath = await fetch(new URL("/mail", running.origin), { method: "POST" });
      expect(wrongPath.status).toBe(404);

      const client = new Client({ name: "gateway-test", version: "1.0.0" });
      await client.connect(new StreamableHTTPClientTransport(running.mcpUrl));
      const listed = await client.listTools();
      expect(listed.tools.map((tool) => tool.name)).toEqual(["mail_server_info"]);
      expect(backend.listSignals).toHaveLength(1);

      const result = await client.callTool(
        { name: "mail_server_info" },
        undefined,
        { signal: new AbortController().signal },
      );
      expect(result.isError).toBe(false);
      expect(backend.calls).toEqual(["mail_server_info"]);
      expect(backend.callSignals).toHaveLength(1);
      await client.close();
    } finally {
      await running.close();
    }
  });

  it("enforces configured browser origins before forwarding requests", async () => {
    const backend = new FakeBackend();
    const running = await startHttpServer(
      tokenConfig({ allowedOrigins: ["https://claude.ai"] }),
      backend,
    );
    try {
      const response = await fetch(running.mcpUrl, {
        method: "POST",
        headers: { Origin: "https://evil.example" },
      });
      expect(response.status).toBe(403);
      expect(backend.calls).toEqual([]);
    } finally {
      await running.close();
    }
  });

  it("validates Cloudflare Access assertions at the MCP origin", async () => {
    const backend = new FakeBackend();
    const verified: string[] = [];
    const running = await startHttpServer(
      tokenConfig({
        auth: {
          kind: "cloudflare",
          teamDomain: "team.cloudflareaccess.com",
          audience: "audience",
        },
      }),
      backend,
      {
        verifier: {
          async verify(assertion: string): Promise<void> {
            verified.push(assertion);
            if (assertion !== "valid-access-assertion") throw new Error("invalid assertion");
          },
        },
      },
    );
    try {
      const missing = await fetch(running.mcpUrl, { method: "POST" });
      expect(missing.status).toBe(401);

      const invalid = await fetch(running.mcpUrl, {
        method: "POST",
        headers: { "Cf-Access-Jwt-Assertion": "invalid-access-assertion" },
      });
      expect(invalid.status).toBe(401);

      const valid = await fetch(running.mcpUrl, {
        method: "POST",
        headers: { "Cf-Access-Jwt-Assertion": "valid-access-assertion" },
      });
      expect(valid.status).not.toBe(401);
      expect(verified).toEqual(["invalid-access-assertion", "valid-access-assertion"]);
    } finally {
      await running.close();
    }
  });
});
