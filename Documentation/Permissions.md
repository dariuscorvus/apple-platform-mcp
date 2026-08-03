# Permissions and packaging

The primary runtime is a background macOS application bundle that exposes its embedded executable through `stdio`.

Executable path inside a Debug build:

```text
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp
```

The bundle contains:

- `NSAppleEventsUsageDescription`
- `com.apple.security.automation.apple-events`
- no Accessibility entitlement
- no Full Disk Access requirement

The Release configuration enables Hardened Runtime. `doctor` fails a signed distribution build that lacks Hardened Runtime or the Apple Events entitlement.

The adapter performs a non-prompting Apple Events permission check before reading Mail. An MCP request never opens a TCC consent prompt. Use `apple-platform-mcp .../apple-platform-mcp doctor` to inspect state without reading account or message data.

The explicit setup command is the only prompt-capable path:

```sh
apple-platform-mcp doctor --request-automation
```

It sends one harmless request for Mail.app's name. macOS then shows the Automation consent prompt for the signed `Apple Platform MCP` host. Allow Mail for that host, rerun the command, and require a `pass` result before starting the MCP server.

## Development

Unsigned development builds can compile and run the stdio protocol, but they are not distribution-ready. TCC behavior must be verified with a signed build under a dedicated macOS test account.

## Distribution gate

Before a release:

- sign with Developer ID Application
- enable Hardened Runtime
- retain only the Apple Events entitlement required by the adapter
- verify the first-run Automation prompt
- verify denial and recovery
- verify upgrade behavior
- notarize and staple the release artifact

No personal mailbox should be used as an integration fixture.
