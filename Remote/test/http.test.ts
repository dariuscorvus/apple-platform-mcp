import { connect as netConnect } from "node:net";
import { APPLE_AREAS } from "../src/areas.js";
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

  public constructor(names?: string[]) {
    if (names) this.tools = names.map((name) => ({ name, inputSchema: { type: "object" } }));
  }

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

describe("scoped Apple connections", () => {
  const names = APPLE_AREAS.map((area) => `${area.toolPrefix}fixture`);
  for (const kind of ["cloudflare", "token"] as const) {
    it(`isolates all six catalogs and calls with ${kind} authentication, retaining legacy compatibility`, async () => {
      const backend = new FakeBackend([...names, "unknown_fixture"]);
      const running = await startHttpServer(tokenConfig(kind === "cloudflare" ? {
        auth: { kind, teamDomain: "team.cloudflareaccess.com", audience: "audience" },
      } : {}), backend, { verifier: { async verify(jwt) { if (jwt !== "valid") throw new Error("denied"); } } });
      const clients: Client[] = [];
      const headers: Record<string, string> = kind === "cloudflare" ? { "Cf-Access-Jwt-Assertion": "valid" } : {};
      try {
        for (const area of APPLE_AREAS) {
          const path = kind === "token" ? `${area.path}/${TOKEN}` : area.path;
          const client = new Client({ name: "area-test", version: "1.0" }); clients.push(client);
          await client.connect(new StreamableHTTPClientTransport(new URL(path, running.origin), { requestInit: { headers } }));
          expect(client.getServerVersion()?.name).toBe(`apple-${area.name}-mcp`);
          expect((await client.listTools()).tools.map((tool) => tool.name)).toEqual([`${area.toolPrefix}fixture`]);
          expect((await client.callTool({ name: `${area.toolPrefix}fixture` })).isError).toBe(false);
          for (const foreign of names.filter((name) => !name.startsWith(area.toolPrefix))) {
            await expect(client.callTool({ name: foreign })).rejects.toThrow("not available");
          }
          await expect(client.callTool({ name: `${area.toolPrefix}nonexistent` })).rejects.toThrow("not available");
          await expect(client.callTool({ name: "unknown_fixture" })).rejects.toThrow("not available");
        }
        // Concurrent open connections must never overwrite another connection's scope.
        expect(await Promise.all(clients.map(async (client) => (await client.listTools()).tools.map((tool) => tool.name)))).toEqual(names.map((name) => [name]));
        expect(backend.calls).toEqual(names);
        const legacy = new Client({ name: "legacy", version: "1.0" });clients.push(legacy);
        await legacy.connect(new StreamableHTTPClientTransport(running.mcpUrl, { requestInit: { headers } }));
        expect((await legacy.listTools()).tools.map((tool) => tool.name)).toEqual([...names, "unknown_fixture"]);
      } finally { await Promise.all(clients.map((client) => client.close())); await running.close(); }
    });
  }

  it("requires Cloudflare authentication and allowed origins on every area", async () => {
    const backend = new FakeBackend(names);
    const running = await startHttpServer(tokenConfig({
      auth: { kind: "cloudflare", teamDomain: "team.cloudflareaccess.com", audience: "audience" }, allowedOrigins: ["https://allowed.example"],
    }), backend, { verifier: { async verify(jwt) { if (jwt !== "valid") throw new Error("denied"); } } });
    try {
      for (const area of APPLE_AREAS) {
        const url = new URL(area.path, running.origin);
        expect((await fetch(url, { method: "POST" })).status).toBe(401);
        expect((await fetch(url, { method: "POST", headers: { "Cf-Access-Jwt-Assertion": "invalid" } })).status).toBe(401);
        expect((await fetch(url, { method: "POST", headers: { "Cf-Access-Jwt-Assertion": "valid", Origin: "https://evil.example" } })).status).toBe(403);
        expect((await fetch(url, { headers: { "Cf-Access-Jwt-Assertion": "valid" } })).status).toBe(405);
      }
      expect(backend.calls).toEqual([]);
    } finally { await running.close(); }
  });

  it("rejects bad tokens, unknown routes and raw path aliases before backend discovery", async () => {
    const backend = new FakeBackend(names); const running = await startHttpServer(tokenConfig(), backend);
    try {
      const paths = APPLE_AREAS.flatMap((a) => [a.path, `${a.path}/wrong`, `${a.path}/${TOKEN}/`, `${a.path}/${TOKEN}/extra`]);
      paths.push(`/apple/unknown/${TOKEN}`, `/apple/%6dail/${TOKEN}`, `/apple/notes/../mail/${TOKEN}`, `/apple/notes/%2e%2e/mail/${TOKEN}`);
      for (const path of paths) {
        const status = await new Promise<number | undefined>((resolve, reject) => {
          // Send the literal request target; older Bun node:http clients normalize dots.
          const socket = netConnect(Number(running.origin.port), running.origin.hostname);
          let response = "";
          socket.on("connect", () => socket.write(`POST ${path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`));
          socket.on("data", (chunk) => { response += chunk.toString(); });
          socket.on("end", () => resolve(Number(response.split(" ")[1])));
          socket.on("error", reject);
        });
        expect(status).toBe(404);
      }
      expect(backend.listSignals).toEqual([]); expect(backend.calls).toEqual([]);
    } finally { await running.close(); }
  });

  it("reserves /apple for scoped routes instead of allowing an unrestricted alias", async () => {
    for (const path of ["/apple", "/apple/mail", "/apple/custom"]) {
      await expect(startHttpServer(tokenConfig({ endpointPath: path }), new FakeBackend())).rejects.toThrow("reserved /apple");
    }
  });
});
