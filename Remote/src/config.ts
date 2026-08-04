import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";

const MIN_TOKEN_LENGTH = 32;
export const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const MIN_REQUEST_TIMEOUT_MS = 100;
const MAX_REQUEST_TIMEOUT_MS = 600_000;

export type GatewayAuth =
  | {
      kind: "cloudflare";
      teamDomain: string;
      audience: string;
      email?: string;
    }
  | {
      kind: "token";
      token: string;
    };

export interface GatewayConfig {
  executable: string;
  args: string[];
  cwd?: string;
  host: string;
  port: number;
  endpointPath: string;
  requestTimeoutMs: number;
  allowedOrigins: string[];
  auth: GatewayAuth;
}

export async function loadGatewayConfig(
  env: Record<string, string | undefined> = process.env,
): Promise<GatewayConfig> {
  const executable = required(env, "APPLE_PLATFORM_MCP_EXECUTABLE");
  const args = parseArguments(env["APPLE_PLATFORM_MCP_ARGUMENTS_JSON"]);
  const host = env["APPLE_PLATFORM_MCP_HTTP_HOST"]?.trim() || "127.0.0.1";
  const port = parsePort(env["APPLE_PLATFORM_MCP_HTTP_PORT"] ?? "3766");
  const endpointPath = validateEndpointPath(env["APPLE_PLATFORM_MCP_HTTP_PATH"] ?? "/mail");
  const requestTimeoutMs = parseRequestTimeout(
    env["APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS"] ?? String(DEFAULT_REQUEST_TIMEOUT_MS),
  );
  const allowedOrigins = (env["APPLE_PLATFORM_MCP_HTTP_ORIGINS"] ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);

  const teamDomain = env["APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN"]?.trim();
  const audience = env["APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE"]?.trim();
  const token = await loadToken(env);

  let auth: GatewayAuth;
  if (teamDomain || audience) {
    if (!teamDomain || !audience) {
      throw new Error(
        "Both APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN and APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE are required.",
      );
    }
    if (token) {
      throw new Error("Configure Cloudflare Access or a capability token, not both.");
    }
    auth = {
      kind: "cloudflare",
      teamDomain,
      audience,
      ...(env["APPLE_PLATFORM_MCP_CF_ACCESS_EMAIL"]?.trim()
        ? { email: env["APPLE_PLATFORM_MCP_CF_ACCESS_EMAIL"].trim() }
        : {}),
    };
  } else {
    if (!token) {
      throw new Error(
        "Set Cloudflare Access variables or APPLE_PLATFORM_MCP_HTTP_TOKEN(_FILE) for remote HTTP.",
      );
    }
    auth = { kind: "token", token };
  }

  return {
    executable,
    args,
    ...(env["APPLE_PLATFORM_MCP_WORKING_DIRECTORY"]?.trim()
      ? { cwd: env["APPLE_PLATFORM_MCP_WORKING_DIRECTORY"].trim() }
      : {}),
    host,
    port,
    endpointPath,
    requestTimeoutMs,
    allowedOrigins,
    auth,
  };
}

export function validateEndpointPath(value: string): string {
  if (
    !value.startsWith("/") ||
    value === "/" ||
    value.endsWith("/") ||
    value.includes("?") ||
    value.includes("#") ||
    value.split("/").some((segment) => segment === "." || segment === "..")
  ) {
    throw new Error(`Invalid APPLE_PLATFORM_MCP_HTTP_PATH: ${value}`);
  }
  return value;
}

function required(env: Record<string, string | undefined>, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function parsePort(value: string): number {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error(`Invalid APPLE_PLATFORM_MCP_HTTP_PORT: ${value}`);
  }
  return port;
}

function parseRequestTimeout(value: string): number {
  const timeout = Number(value);
  if (
    !Number.isInteger(timeout) ||
    timeout < MIN_REQUEST_TIMEOUT_MS ||
    timeout > MAX_REQUEST_TIMEOUT_MS
  ) {
    throw new Error(
      `Invalid APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS: ${value} (expected ${MIN_REQUEST_TIMEOUT_MS}-${MAX_REQUEST_TIMEOUT_MS}).`,
    );
  }
  return timeout;
}

function parseArguments(value: string | undefined): string[] {
  if (!value?.trim()) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error("APPLE_PLATFORM_MCP_ARGUMENTS_JSON must be a JSON array of strings.");
  }
  if (!Array.isArray(parsed) || !parsed.every((argument) => typeof argument === "string")) {
    throw new Error("APPLE_PLATFORM_MCP_ARGUMENTS_JSON must be a JSON array of strings.");
  }
  return parsed;
}

async function loadToken(env: Record<string, string | undefined>): Promise<string | undefined> {
  const tokenFile = env["APPLE_PLATFORM_MCP_HTTP_TOKEN_FILE"]?.trim();
  const token = tokenFile
    ? (await readFile(expandHome(tokenFile), "utf8")).trim()
    : env["APPLE_PLATFORM_MCP_HTTP_TOKEN"]?.trim();
  if (token && token.length < MIN_TOKEN_LENGTH) {
    throw new Error(
      `APPLE_PLATFORM_MCP_HTTP_TOKEN(_FILE) must contain at least ${MIN_TOKEN_LENGTH} characters.`,
    );
  }
  return token || undefined;
}

function expandHome(value: string): string {
  return value === "~" ? homedir() : value.startsWith("~/") ? resolve(homedir(), value.slice(2)) : value;
}
