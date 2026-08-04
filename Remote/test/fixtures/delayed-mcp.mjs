import { existsSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const delayMs = Number(process.argv[2] ?? "0");
const exitMarkerPath = process.argv[3];
const startupDelayMs = Number(process.argv[4] ?? "0");
let exitScheduled = false;
const tools = [
  {
    name: "mail_server_info",
    description: "Synthetic timing fixture.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
];

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function handleMessage(message) {
  if (message.method === "initialize") {
    await sleep(startupDelayMs);
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: message.params?.protocolVersion ?? "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: { name: "synthetic-timing-fixture", version: "1.0.0" },
      },
    });
    return;
  }

  if (message.method === "tools/list") {
    await sleep(startupDelayMs);
    send({ jsonrpc: "2.0", id: message.id, result: { tools } });
    return;
  }

  if (message.method === "tools/call") {
    await sleep(delayMs);
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        content: [{ type: "text", text: JSON.stringify({ success: true }) }],
        isError: false,
      },
    });

    if (exitMarkerPath && !exitScheduled && !existsSync(exitMarkerPath)) {
      exitScheduled = true;
      writeFileSync(exitMarkerPath, "exited\n");
      setImmediate(() => process.exit(0));
    }
  }
}

const input = createInterface({ input: process.stdin });
for await (const line of input) {
  if (!line.trim()) continue;

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    continue;
  }

  void handleMessage(message);
}
