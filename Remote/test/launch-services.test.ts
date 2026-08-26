import { describe, expect, it } from "bun:test";
import { launchServicesArguments } from "../src/backend.js";

describe("Launch Services backend", () => {
  it("launches the app bundle hidden with a loopback Streamable HTTP transport", () => {
    expect(
      launchServicesArguments(
        "/Applications/apple-platform-mcp.app",
        new URL("http://127.0.0.1:8765/mcp"),
      ),
    ).toEqual([
      "-gj",
      "-n",
      "/Applications/apple-platform-mcp.app",
      "--args",
      "serve",
      "--transport",
      "streamable-http",
      "--host",
      "127.0.0.1",
      "--port",
      "8765",
    ]);
  });

  it("rejects non-loopback backend URLs", () => {
    expect(() =>
      launchServicesArguments(
        "/Applications/apple-platform-mcp.app",
        new URL("http://192.0.2.10:8765/mcp"),
      ),
    ).toThrow(/127\.0\.0\.1/);
  });
});
