/** Opt-in signed-host acceptance. Creates only a new disposable iCloud folder.
 * bun run scripts/icloud-smoke.ts /absolute/signed/apple-platform-mcp
 * Uses a temporary --config; never edits the installed host configuration.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { mkdtemp, mkdir, writeFile, readFile, appendFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { SwiftStdioBackend } from "../src/backend.js";
import { startHttpServer } from "../src/http.js";
const run = promisify(execFile);
const executable = resolve(process.argv[2] ?? "");
if (!process.argv[2]?.startsWith("/")) throw Error("Pass an absolute path to the signed test executable");
await run("/usr/bin/codesign", ["--verify", "--strict", executable]);
const scratch = await mkdtemp(join(tmpdir(), "apple-icloud-smoke-"));
const root = join(homedir(), "Library/Mobile Documents/com~apple~CloudDocs", "ApplePlatformMCP-Smoke-" + randomUUID());
await mkdir(root); // new folder only; root validation remains the server's responsibility
const configuration = join(scratch, "config.json");
await writeFile(configuration, JSON.stringify({ icloud_roots: [{ id: randomUUID(), name: "Disposable smoke fixture", path: root }], icloud_mutation_mode: "allowed", icloud_trash_enabled: true }));
const report: Record<string, unknown> = { root, scratch, local: {}, crossDeviceSync: "not observed", eviction: "not attempted" };
const token = randomUUID() + randomUUID();
const bytes = Buffer.alloc(700123); for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
const sha = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
async function exercise(client: Client, transport: string) {
  const call = async (operation: string, args: Record<string, unknown> = {}): Promise<any> => {
    const result = await client.callTool({ name: "icloud_" + operation, arguments: args });
    const envelope = result.structuredContent as any;
    if (!envelope?.success) throw Error(JSON.stringify(envelope));
    return envelope.data;
  };
  const mutate = (operation: string, args: Record<string, unknown>) => call(operation, { ...args, idempotency_key: randomUUID() });
  let roots: any;
  for (let n = 0; n < 20; n++) {
    try { roots = await call("list_roots"); break; }
    catch (error) { if (n === 19) throw error; await Bun.sleep(1000); }
  }
  const rootID = roots[0].item_id;
  const tools = (await client.listTools()).tools.filter(t => t.name.startsWith("icloud_"));
  if (tools.length !== 16) throw Error("Missing iCloud tools");
  const folder = await mutate("create_folder", { parent_id: rootID, name: transport });
  const nested = await mutate("create_folder", { parent_id: folder.item_id, name: "nested" });
  async function upload(name: string, data: Buffer) {
    const started = await mutate("begin_upload", { parent_id: folder.item_id, name, size: data.length, sha256: sha(data) });
    for (let offset = 0; offset < data.length; offset += 262144) {
      const args = { upload_id: started.upload_id, offset, data: data.subarray(offset, offset + 262144).toString("base64"), idempotency_key: randomUUID() };
      await call("upload_chunk", args); await call("upload_chunk", args);
    }
    const args = { upload_id: started.upload_id, idempotency_key: randomUUID() };
    const item = await call("commit_upload", args); await call("commit_upload", args); return item;
  }
  let binary = await upload("binary.dat", bytes);
  const parts: Buffer[] = [];
  for (let offset = 0; offset < bytes.length; offset += 262144) {
    const result = await call("read_file", { item_id: binary.item_id, revision: binary.revision, offset });
    parts.push(Buffer.from(result.data, "base64"));
  }
  if (!Buffer.concat(parts).equals(bytes)) throw Error("Binary roundtrip mismatch");
  const text = await upload("text.txt", Buffer.from("Grüße aus dem iCloud-Smoke-Test\n", "utf8"));
  const content = await call("read_file", { item_id: text.item_id, revision: text.revision, encoding: "utf8" });
  if (content.data !== "Grüße aus dem iCloud-Smoke-Test\n") throw Error("Text mismatch");
  await mutate("copy_item", { item_id: binary.item_id, revision: binary.revision, parent_id: nested.item_id, name: "copy.dat" });
  binary = await mutate("rename_item", { item_id: binary.item_id, revision: binary.revision, name: "renamed.dat" });
  binary = await mutate("move_item", { item_id: binary.item_id, revision: binary.revision, parent_id: nested.item_id, name: "moved.dat" });
  await mutate("trash_item", { item_id: binary.item_id, revision: binary.revision });
  const results = await call("search_items", { item_id: folder.item_id, query: ".txt", limit: 1 });
  if (results.items.length !== 1) throw Error("Search mismatch");
  (report.local as any)[transport] = { binaryBytes: bytes.length, sha256: sha(bytes), text: true, copy: true, rename: true, move: true, trash: true, discoveredTools: tools.length };
  // Leave only the text fixture for a later cross-device/eviction check.
  return { call, text, folder };
}
try {
  const stdio = new Client({ name: "icloud-signed-smoke", version: "1" });
  await stdio.connect(new StdioClientTransport({ command: executable, args: ["serve", "--transport", "stdio", "--config", configuration] }));
  const fixture = await exercise(stdio, "stdio");
  // Eviction can require a completed upload; record whether macOS actually evicted it.
  const textPath = join(root, "stdio/text.txt");
  try {
    for (let n = 0; n < 20; n++) {
      const uploaded = await fixture.call("get_item", { item_id: fixture.text.item_id });
      report.uploadedBeforeEviction = uploaded.is_uploaded ?? "unknown";
      if (uploaded.is_uploaded === true) break;
      await Bun.sleep(1000);
    }
    await run("/usr/bin/brctl", ["evict", textPath], { timeout: 10000 });
    let evicted = await fixture.call("get_item", { item_id: fixture.text.item_id });
    for (let n = 0; n < 10 && evicted.download_status !== "NSURLUbiquitousItemDownloadingStatusNotDownloaded"; n++) {
      await Bun.sleep(500);
      evicted = await fixture.call("get_item", { item_id: fixture.text.item_id });
    }
    report.eviction = { requested: true, observedStatus: evicted.download_status ?? "unknown" };
    const result = await fixture.call("download_item", { item_id: fixture.text.item_id });
    report.downloadRequest = result.status ?? result.download_status;
    if (evicted.download_status === "NSURLUbiquitousItemDownloadingStatusNotDownloaded") {
      report.evictedFileExercised = true;
      for (let n = 0; n < 30; n++) {
        const fresh = await fixture.call("get_item", { item_id: fixture.text.item_id });
        const read = await fixture.call("read_file", { item_id: fresh.item_id, revision: fresh.revision, encoding: "utf8" });
        if (read.status !== "download_pending") { report.downloadedText = read.data === "Grüße aus dem iCloud-Smoke-Test\n"; break; }
        await Bun.sleep(1000);
      }
    }
  } catch (error) { report.eviction = { requested: true, error: String(error) }; }
  await stdio.close();
  // Reserve an ephemeral loopback port without assuming the installed host port is free.
  const probe = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() });
  const port = probe.port!; probe.stop(true);
  const child = spawn(executable, ["serve", "--transport", "streamable-http", "--host", "127.0.0.1", "--port", String(port), "--config", configuration], { stdio: ["ignore", "pipe", "pipe"] });
  child.stderr.on("data", data => { void appendFile(join(scratch, "native-http.stderr.log"), data); });
  child.stdout.on("data", data => { void appendFile(join(scratch, "native-http.stdout.log"), data); });
  child.on("exit", (code, signal) => { report.nativeExit = { code, signal }; });
  try {
    for (let n = 0; n < 50; n++) { try { await fetch(`http://127.0.0.1:${port}/healthz`); break; } catch { await Bun.sleep(100); } }
    const http = new Client({ name: "icloud-http-smoke", version: "1" });
    await http.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
    await exercise(http, "native-http"); await http.close();
  } finally { child.kill("SIGTERM"); }
  const backend = new SwiftStdioBackend({ executable, args: ["serve", "--transport", "stdio", "--config", configuration], requestTimeoutMs: 60000 });
  const gateway = await startHttpServer({ backend: { kind: "stdio", executable, args: [] }, host: "127.0.0.1", port: 0, endpointPath: "/files", requestTimeoutMs: 60000, allowedOrigins: [], auth: { kind: "token", token } }, backend);
  try {
    const remote = new Client({ name: "icloud-gateway-smoke", version: "1" });
    await remote.connect(new StreamableHTTPClientTransport(gateway.mcpUrl));
    await exercise(remote, "remote-gateway"); await remote.close();
  } finally { await gateway.close(); await backend.close(); }
  report.signedExecutableSHA256 = sha(await readFile(executable));
  report.localSuccess = true;
  report.acceptanceComplete = report.evictedFileExercised === true && report.downloadedText === true && report.crossDeviceSync !== "not observed";
} catch (error) { report.localSuccess = false; report.acceptanceComplete = false; report.error = String(error); process.exitCode = 1; }
await writeFile(join(scratch, "report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
