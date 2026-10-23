import { describe, expect, it } from "bun:test";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("../../Scripts/mail-watchdog.sh", import.meta.url).pathname;

async function fakeCommand(path: string, body: string): Promise<void> {
  await writeFile(path, `#!/bin/sh\n${body}\n`);
  await chmod(path, 0o755);
}

type WatchdogResult = {
  code: number;
  openArguments: string;
  pgrepArguments: string;
  stderr: string;
};

async function runWatchdog(
  appRunning: boolean,
  options: { app?: string; openExitCode?: number; interval?: string } = {},
): Promise<WatchdogResult> {
  const directory = await mkdtemp(join(tmpdir(), "apple-platform-mail-watchdog-"));
  const openLog = join(directory, "open.log");
  const pgrepLog = join(directory, "pgrep.log");
  const pgrep = join(directory, "pgrep");
  const open = join(directory, "open");
  await fakeCommand(
    pgrep,
    `printf '%s\\n' "$*" > "${pgrepLog}"\nexit ${appRunning ? 0 : 1}`,
  );
  await fakeCommand(
    open,
    `printf '%s\\n' "$*" > "${openLog}"\nexit ${options.openExitCode ?? 0}`,
  );

  const proc = Bun.spawn([script], {
    env: {
      ...process.env,
      APPLE_PLATFORM_MCP_MAIL_WATCHDOG_ONCE: "1",
      APPLE_PLATFORM_MCP_MAIL_WATCHDOG_PGREP: pgrep,
      APPLE_PLATFORM_MCP_MAIL_WATCHDOG_OPEN: open,
      ...(options.interval
        ? { APPLE_PLATFORM_MCP_MAIL_WATCHDOG_INTERVAL_SECONDS: options.interval }
        : {}),
      ...(options.app ? { APPLE_PLATFORM_MCP_MAIL_WATCHDOG_APP: options.app } : {}),
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stderr).text(),
  ]);
  return {
    code,
    openArguments: await readFile(openLog, "utf8").catch(() => ""),
    pgrepArguments: await readFile(pgrepLog, "utf8").catch(() => ""),
    stderr,
  };
}

describe("Mail.app watchdog", () => {
  it("starts Mail.app hidden when its process is absent", async () => {
    const result = await runWatchdog(false);

    expect(result.code).toBe(0);
    expect(result.pgrepArguments).toBe("-x Mail\n");
    expect(result.openArguments).toBe("-gj -a Mail\n");
  });

  it("leaves an already-running Mail.app untouched", async () => {
    const result = await runWatchdog(true);

    expect(result.code).toBe(0);
    expect(result.pgrepArguments).toBe("-x Mail\n");
    expect(result.openArguments).toBe("");
  });

  it("accepts an explicit Mail.app path for non-standard installations", async () => {
    const result = await runWatchdog(false, { app: "/System/Applications/Mail.app" });

    expect(result.openArguments).toBe("-gj -a /System/Applications/Mail.app\n");
  });

  it("reports a failed Launch Services start without crashing the watchdog", async () => {
    const result = await runWatchdog(false, { openExitCode: 1 });

    expect(result.code).toBe(0);
    expect(result.stderr).toMatch(/failed to start Mail\.app/);
  });

  it("rejects a zero or malformed interval before entering the loop", async () => {
    const zero = await runWatchdog(false, { interval: "0" });
    const malformed = await runWatchdog(false, { interval: "not-a-number" });

    expect(zero.code).toBe(64);
    expect(zero.stderr).toMatch(/at least one second/);
    expect(malformed.code).toBe(64);
    expect(malformed.stderr).toMatch(/invalid watchdog interval/);
  });
});
