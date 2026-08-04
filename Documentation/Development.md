# Development

## Generate the Xcode project

```sh
xcodegen generate --spec project.yml
```

`project.yml` is the source of truth. The generated `.xcodeproj`, shared scheme, and `Package.resolved` remain checked in so the project opens directly in Xcode.

The product is a background app bundle because Apple Events permission and signing are bundle-scoped. MCP clients invoke the embedded executable directly.

## Regenerate the Mail bridge

The generated bridge is tied to the Mail.app scripting definition installed on the machine. Regenerate all three checked-in artifacts together:

```sh
Scripts/generate-mail-bridge.sh
```

The script runs `sdef` and `sdp` against `/System/Applications/Mail.app`. Review the generated diff before building.

## Format

```sh
xcrun swift-format format --in-place --recursive Sources Tests
xcrun swift-format lint --recursive Sources Tests
```

## Build and test

For the fastest local feedback loop, build and run the contract tests with Swift Package Manager:

```sh
swift test
```

The package manifest models the generated Mail ScriptingBridge as a separate Objective-C target.
The Xcode project remains the source of truth for app bundling, entitlements, signing, archiving,
and distribution.

Use a fresh derived-data and Swift package cache directory for reproducible local checks:

```sh
xcodebuild \
  -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/apple-platform-mcp-derived \
  -clonedSourcePackagesDirPath /tmp/apple-platform-mcp-packages \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Run the same command with `test` instead of `build` for the unit and contract test target.

For a local signed build, archive the app with a Developer ID identity and run the embedded executable from the archive:

```sh
xcodebuild \
  -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/apple-platform-mcp.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application: <name> (<team>)' \
  DEVELOPMENT_TEAM='<team>' \
  archive

/tmp/apple-platform-mcp.xcarchive/Products/Applications/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp doctor --request-automation
```

The signed app must be used for Automation testing. A bare `apple-platform-mcp` command is not installed by the Xcode project.

## Run the MCP server

The default command remains backward-compatible with existing MCP client configurations:

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp
```

The equivalent explicit command is:

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp serve --transport stdio
```

Streamable HTTP is an explicit, loopback-only mode:

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp serve --transport streamable-http
```

It listens on `127.0.0.1:8765` by default. A different loopback port can be selected explicitly:

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp serve \
  --transport streamable-http \
  --host 127.0.0.1 \
  --port 9000
```

The MCP endpoint is `POST /mcp`. Process liveness is available at `GET /health/live`, and a
sanitized Mail/TCC readiness result is available at `GET /health/ready`. Non-loopback bind
addresses are rejected. The listener requires the exact `127.0.0.1:<bound-port>` Host authority on
all routes and accepts an Origin only when it matches that authority. It rejects declared or observed
oversized bodies immediately. Request reading is limited to 15 seconds, each connection to 45
seconds, accepted connections to 32, concurrent MCP requests to four, and MCP response waiting to 30
seconds. A response timeout or client disconnect forwards best-effort MCP cancellation to the SDK.
Every HTTP request attempt receives a fresh internal SDK correlation ID, while responses restore the
client's original numeric or string ID. Late responses therefore cannot satisfy a newer reuse, even
when a handler ignores cancellation, and correlation state remains bounded to active requests. Each
connection serves one request and closes after its response. This stateless listener uses one long-lived
MCP server and is intended for one local client.
Do not expose this unauthenticated HTTP origin directly to a LAN or the internet; remote access
requires a separate HTTPS and identity-aware authentication layer.

## Build the remote gateway

The optional `Remote/` package keeps the Swift MCP server local and adds a
Streamable HTTP gateway for remote MCP clients. The gateway starts the signed
Swift executable as a stdio child process, so Mail.app and its Automation
permission remain on the Mac that owns the mail.

```sh
cd Remote
bun install --frozen-lockfile
bun run typecheck
bun test
bun run build
```

The remote test suite includes a synthetic stdio MCP fixture that delays a tool
response, verifies the configured backend request timeout, and confirms that
the gateway reconnects after the child exits. It never starts Mail.app and
never uses personal mailbox data. Configure the production bound with
`APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS` when the default 60-second limit is not
appropriate.

See [Remote-Deployment.md](Remote-Deployment.md) for Cloudflare Tunnel,
Cloudflare Access, Claude, ChatGPT, and launchd setup.

## Diagnose the host

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp doctor
```

The output contains only platform, signing, policy, configuration, and Mail/TCC status. It never lists accounts or reads message data.

## Configuration

The optional file is:

```text
~/.config/apple-platform-mcp/config.json
```

The bootstrap uses JSON so the local server has no YAML parser dependency. The file contains policy references and limits only; Mail.app remains the owner of account credentials.

An absent file means read-only defaults. Invalid configuration fails closed. Write modes are not accepted.
