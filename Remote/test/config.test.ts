import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "bun:test";
import { loadGatewayConfig } from "../src/config.js";

const executable = "/Applications/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp";

describe("remote gateway configuration", () => {
  it("loads a Launch Services backend configuration", async () => {
    const config = await loadGatewayConfig({
      APPLE_PLATFORM_MCP_APP_BUNDLE: "/Applications/apple-platform-mcp.app",
      APPLE_PLATFORM_MCP_EXECUTABLE: executable,
      APPLE_PLATFORM_MCP_LOCAL_HTTP_URL: "http://127.0.0.1:8765/mcp",
      APPLE_PLATFORM_MCP_HTTP_TOKEN: "0123456789abcdef0123456789abcdef",
    });

    expect(config.backend).toEqual({
      kind: "launch-services",
      appBundle: "/Applications/apple-platform-mcp.app",
      url: "http://127.0.0.1:8765/mcp",
    });
  });

  it("loads Cloudflare Access configuration and optional process settings", async () => {
    const config = await loadGatewayConfig({
      APPLE_PLATFORM_MCP_EXECUTABLE: executable,
      APPLE_PLATFORM_MCP_ARGUMENTS_JSON: '["doctor"]',
      APPLE_PLATFORM_MCP_WORKING_DIRECTORY: "/Users/example",
      APPLE_PLATFORM_MCP_HTTP_HOST: "127.0.0.1",
      APPLE_PLATFORM_MCP_HTTP_PORT: "3766",
      APPLE_PLATFORM_MCP_HTTP_PATH: "/mail",
      APPLE_PLATFORM_MCP_HTTP_ORIGINS: "https://claude.ai, https://chatgpt.com",
      APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com",
      APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE: "application-audience",
      APPLE_PLATFORM_MCP_CF_ACCESS_EMAIL: "you@example.com",
    });

    expect(config).toEqual({
      backend: {
        kind: "stdio",
        executable,
        args: ["doctor"],
        cwd: "/Users/example",
      },
      host: "127.0.0.1",
      port: 3766,
      endpointPath: "/mail",
      requestTimeoutMs: 60_000,
      allowedOrigins: ["https://claude.ai", "https://chatgpt.com"],
      auth: {
        kind: "cloudflare",
        teamDomain: "team.cloudflareaccess.com",
        audience: "application-audience",
        email: "you@example.com",
      },
    });
  });

  it("loads a capability token from a file for private testing", async () => {
    const directory = await mkdtemp(join(tmpdir(), "apple-platform-mcp-"));
    const tokenFile = join(directory, "token");
    try {
      await writeFile(tokenFile, "0123456789abcdef0123456789abcdef\n", "utf8");
      const config = await loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_HTTP_TOKEN_FILE: tokenFile,
      });
      expect(config.auth).toEqual({
        kind: "token",
        token: "0123456789abcdef0123456789abcdef",
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("rejects incomplete or conflicting authentication settings", async () => {
    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com",
      }),
    ).rejects.toThrow("Both APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN");

    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com",
        APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE: "audience",
        APPLE_PLATFORM_MCP_HTTP_TOKEN: "0123456789abcdef0123456789abcdef",
      }),
    ).rejects.toThrow("Configure Cloudflare Access or a capability token");

    await expect(
      loadGatewayConfig({ APPLE_PLATFORM_MCP_EXECUTABLE: executable }),
    ).rejects.toThrow("Set Cloudflare Access variables");
  });

  it("rejects unsafe endpoint paths and weak tokens", async () => {
    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_HTTP_PATH: "/mail/../admin",
        APPLE_PLATFORM_MCP_HTTP_TOKEN: "0123456789abcdef0123456789abcdef",
      }),
    ).rejects.toThrow("Invalid APPLE_PLATFORM_MCP_HTTP_PATH");

    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_HTTP_TOKEN: "too-short",
      }),
    ).rejects.toThrow("must contain at least 32 characters");

    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_HTTP_TOKEN: "0123456789abcdef0123456789abcdef",
        APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS: "99",
      }),
    ).rejects.toThrow("Invalid APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS");

    await expect(
      loadGatewayConfig({
        APPLE_PLATFORM_MCP_EXECUTABLE: executable,
        APPLE_PLATFORM_MCP_HTTP_TOKEN: "0123456789abcdef0123456789abcdef",
        APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS: "600001",
      }),
    ).rejects.toThrow("Invalid APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS");
  });
});
