import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import {
  CallToolResultSchema,
  type CallToolResult,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";

export interface SwiftBackendOptions {
  executable: string;
  args: string[];
  cwd?: string;
  requestTimeoutMs: number;
}

export interface MCPBackend {
  start(signal?: AbortSignal): Promise<void>;
  listTools(signal?: AbortSignal): Promise<Tool[]>;
  callTool(
    name: string,
    args?: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<CallToolResult>;
  ping(signal?: AbortSignal): Promise<void>;
  close(): Promise<void>;
}

export class SwiftStdioBackend implements MCPBackend {
  private client: Client;
  private tools: Tool[] | undefined;
  private startTask: Promise<void> | undefined;
  private startGeneration: number | undefined;
  private lifecycleGeneration = 0;

  public constructor(private readonly options: SwiftBackendOptions) {
    this.client = this.createClient();
  }

  public async start(signal?: AbortSignal): Promise<void> {
    if (!this.startTask) {
      const generation = this.lifecycleGeneration;
      const task = this.connect(generation);
      this.startTask = task;
      this.startGeneration = generation;
      void task.catch(() => {
        if (this.startTask !== task) return;
        this.startTask = undefined;
        this.startGeneration = undefined;
      });
    }
    const task = this.startTask;
    const generation = this.startGeneration;
    await waitForAbortable(task, signal);
    if (generation === undefined || this.startTask !== task || this.lifecycleGeneration !== generation) {
      throw new Error("The local MCP backend connection was superseded.");
    }
  }

  public async listTools(signal?: AbortSignal): Promise<Tool[]> {
    await this.start(signal);
    if (this.tools) return [...this.tools];

    const result = await this.client.listTools(undefined, this.requestOptions(signal));
    this.tools = result.tools;
    return [...this.tools];
  }

  public async callTool(
    name: string,
    args?: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<CallToolResult> {
    await this.start(signal);
    const result = await this.client.callTool(
      { name, arguments: args },
      CallToolResultSchema,
      this.requestOptions(signal),
    );
    if (!("content" in result)) {
      throw new Error("The local MCP backend returned an unsupported task result.");
    }
    return result as CallToolResult;
  }

  public async ping(signal?: AbortSignal): Promise<void> {
    await this.start(signal);
    await this.client.ping(this.requestOptions(signal));
  }

  public async close(): Promise<void> {
    this.lifecycleGeneration += 1;
    const client = this.client;
    this.client = this.createClient();
    const startTask = this.startTask;
    this.startTask = undefined;
    this.startGeneration = undefined;
    this.tools = undefined;
    await Promise.allSettled([client.close(), ...(startTask ? [startTask] : [])]);
  }

  private async connect(generation: number): Promise<void> {
    const client = this.createClient();
    this.client = client;
    const transport = new StdioClientTransport({
      command: this.options.executable,
      args: this.options.args,
      ...(this.options.cwd ? { cwd: this.options.cwd } : {}),
      stderr: "inherit",
    });
    try {
      await client.connect(transport, this.requestOptions());
      const result = await client.listTools(undefined, this.requestOptions());
      if (!this.isCurrent(generation, client)) {
        throw new Error("The local MCP backend connection was superseded.");
      }
      this.tools = result.tools;
    } catch (error) {
      await client.close().catch(() => undefined);
      throw error;
    }
  }

  private createClient(): Client {
    const client = new Client({
      name: "apple-platform-mcp-remote-gateway",
      version: "0.1.0",
    });
    client.onclose = () => {
      if (this.client !== client) return;
      this.lifecycleGeneration += 1;
      this.tools = undefined;
      this.startTask = undefined;
      this.startGeneration = undefined;
    };
    return client;
  }

  private isCurrent(generation: number, client: Client): boolean {
    return this.lifecycleGeneration === generation && this.client === client;
  }

  private requestOptions(signal?: AbortSignal): { timeout: number; signal?: AbortSignal } {
    return {
      timeout: this.options.requestTimeoutMs,
      ...(signal ? { signal } : {}),
    };
  }
}

function waitForAbortable<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  signal.throwIfAborted();

  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => {
      try {
        signal.throwIfAborted();
      } catch (error) {
        reject(error);
      }
    };
    const cleanup = (): void => signal.removeEventListener("abort", onAbort);
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error: unknown) => {
        cleanup();
        reject(error);
      },
    );
  });
}
