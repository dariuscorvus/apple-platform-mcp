# Apple Platform MCP

Apple Platform MCP exposes a controlled Model Context Protocol interface to
Mail.app and Apple Reminders on macOS. Mail.app remains the owner of
accounts, credentials, provider authentication, and message storage; the
server uses Apple Events through ScriptingBridge and EventKit for a
policy-controlled Reminders lifecycle.

## Safety defaults

The server is read-only by default:

- `send_mode` defaults to `denied`;
- `mutation_mode` defaults to `denied`;
- `reminder_mutation_mode` defaults to `denied`;
- Reminder list deletion needs a separate explicit policy gate;
- invalid or missing local configuration fails closed;
- permanent Mail deletion and emptying Trash are not exposed;
- Mail content is untrusted data and never authorizes an action.

Mailbox mutations can be enabled explicitly in the local configuration after
reviewing the account and mailbox boundaries. Sending and the Reminders
lifecycle remain separate capabilities.

## Supported surface

The MCP server provides Mail.app discovery, search, message reads, drafts,
same-account moves, archive, reversible Trash moves, and read/flag status
updates, plus Reminders list/reminder reads and an explicit-source list and
Reminder lifecycle after Full Access. Reminder writes stay default-denied,
require per-operation idempotency keys, and use exact opaque references.
The exact tool schemas and policy behavior are documented in
[`Documentation/MCP-API.md`](Documentation/MCP-API.md).

## Build and test

The project targets macOS 13 or later and requires Xcode, XcodeGen, Swift, and
Bun for the remote gateway:

```sh
xcodegen generate --spec project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP -destination 'platform=macOS' \
  -parallel-testing-enabled NO
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

The source line is the working Mail.app V1 plus a current Reminders lifecycle
(R-001 through R-015) verified by an isolated live stdio smoke on macOS 26.6.2
with Full Access. Dedicated macOS 13 runtime/TCC verification remains a
release compatibility gate. A signed and notarized macOS distribution is a
separate release step and must not be inferred from a local debug or ad-hoc
build.

<!-- TASKPLANNER:ATTRIBUTION:START -->
This project uses [TaskPlanner](https://github.com/smekai/taskplanner) for task planning.
<!-- TASKPLANNER:ATTRIBUTION:END -->
