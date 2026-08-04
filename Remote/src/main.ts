import { SwiftStdioBackend } from "./backend.js";
import { loadGatewayConfig } from "./config.js";
import { startHttpServer } from "./http.js";

async function main(): Promise<void> {
  const config = await loadGatewayConfig();
  const backend = new SwiftStdioBackend({
    executable: config.executable,
    args: config.args,
    ...(config.cwd ? { cwd: config.cwd } : {}),
    requestTimeoutMs: config.requestTimeoutMs,
  });

  await backend.start();
  const running = await startHttpServer(config, backend);
  console.error(
    JSON.stringify({
      level: "info",
      message: "Apple Platform MCP remote gateway is listening",
      origin: running.origin.origin,
      endpoint: config.endpointPath,
      auth: config.auth.kind,
    }),
  );

  let shuttingDown = false;
  const shutdown = async (): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    await running.close();
    await backend.close();
  };
  process.once("SIGINT", () => void shutdown().finally(() => process.exit(0)));
  process.once("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`apple-platform-mcp-remote fatal: ${message}\n`);
  process.exit(1);
});
