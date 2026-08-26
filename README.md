# Apple Platform MCP

Apple Platform MCP exposes a controlled Model Context Protocol interface to
Mail.app on macOS. Mail.app remains the owner of accounts, credentials,
provider authentication, and message storage; the server uses Apple Events
through ScriptingBridge.

## Safety defaults

The server is read-only by default:

- `send_mode` defaults to `denied`;
- `mutation_mode` defaults to `denied`;
- invalid or missing local configuration fails closed;
- permanent deletion and emptying Trash are not exposed;
- Mail content is untrusted data and never authorizes an action.

Mailbox mutations can be enabled explicitly in the local configuration after
reviewing the account and mailbox boundaries. Sending remains a separate
capability.

## Supported surface

The MCP server provides Mail.app discovery, search, message reads, drafts,
same-account moves, archive, reversible Trash moves, and read/flag status
updates. The exact tool schemas and policy behavior are documented in
[`Documentation/MCP-API.md`](Documentation/MCP-API.md).

## Build and test

The project targets macOS 13 or later and requires Xcode, XcodeGen, Swift, and
Bun for the remote gateway:

```sh
xcodegen generate --spec project.yml
swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP -destination 'platform=macOS'
cd Remote
bun install --frozen-lockfile
bun run typecheck
bun test
bun run build
```

The signed app bundle is required when testing real Apple Events and Mail.app
access. Follow [`Documentation/Permissions.md`](Documentation/Permissions.md)
for the macOS permission boundary.

## Remote deployment

The optional Node gateway is intended to bind locally and front the Swift
backend through an authenticated deployment such as Cloudflare Access. Keep
the backend on loopback, keep credentials outside the repository, and use the
placeholder configurations under `Examples/remote/` and
[`Documentation/Remote-Deployment.md`](Documentation/Remote-Deployment.md).

Never commit Cloudflare credentials, capability tokens, Mail content, local
launchd files, or deployment logs.

## Project status

The current source line is the Mail.app-only V1. A signed and notarized macOS
distribution is a separate release step and must not be inferred from a local
debug or ad-hoc build.

<!-- TASKPLANNER:ATTRIBUTION:START -->
This project uses [TaskPlanner](https://github.com/smekai/taskplanner) for task planning.
<!-- TASKPLANNER:ATTRIBUTION:END -->
