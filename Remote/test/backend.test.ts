import { access, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "bun:test";
import { SwiftStdioBackend } from "../src/backend.js";

const fixture = join(import.meta.dir, "fixtures", "delayed-mcp.mjs");

describe("Swift stdio backend timing", () => {
  it("bounds a delayed tool call with the configured request timeout", async () => {
    const backend = new SwiftStdioBackend({
      executable: process.execPath,
      args: [fixture, "250"],
      requestTimeoutMs: 100,
    });
    const startedAt = performance.now();

    try {
      await backend.start();
      await expect(backend.callTool("mail_server_info")).rejects.toThrow(/timed out|timeout/i);
      expect(performance.now() - startedAt).toBeLessThan(500);
    } finally {
      await backend.close();
    }
  });

  it("reconnects after the stdio child exits", async () => {
    const directory = await mkdtemp(join(tmpdir(), "apple-platform-mcp-"));
    const markerPath = join(directory, "child-exited");
    const backend = new SwiftStdioBackend({
      executable: process.execPath,
      args: [fixture, "0", markerPath],
      requestTimeoutMs: 500,
    });

    try {
      await backend.start();
      await backend.callTool("mail_server_info");
      await waitForFile(markerPath);

      const result = await backend.callTool("mail_server_info");
      expect(result.isError).toBe(false);
    } finally {
      await backend.close();
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("does not cancel shared startup for another caller", async () => {
    const backend = new SwiftStdioBackend({
      executable: process.execPath,
      args: [fixture, "0", "", "100"],
      requestTimeoutMs: 500,
    });
    const controller = new AbortController();

    try {
      const cancelled = backend.callTool("mail_server_info", undefined, controller.signal);
      await Bun.sleep(10);
      controller.abort();
      await expect(cancelled).rejects.toThrow(/abort/i);

      const result = await backend.callTool("mail_server_info");
      expect(result.isError).toBe(false);
    } finally {
      await backend.close();
    }
  });
});

async function waitForFile(path: string): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await access(path);
      await Bun.sleep(25);
      return;
    } catch {
      await Bun.sleep(10);
    }
  }
  throw new Error(`Timed out waiting for ${path}`);
}
