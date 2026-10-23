# Apple Platform MCP

Apple Platform MCP exposes 51 tools for six macOS services through stdio,
native HTTP, and the authenticated remote gateway. macOS manages account
credentials, permissions, and iCloud synchronization.

## Supported surface

| Service | Tools | Capabilities |
| --- | ---: | --- |
| Mail | 11 | Discover, search, read, draft, send, move, archive, Trash, read/flag status, diagnostics |
| Reminders | 10 | Lists and reminders, including policy-controlled lifecycle operations |
| Notes | 5 | Accounts, folders, title search, plain-text reads, text-note creation |
| Calendar | 6 | Calendars, search, occurrences, conflicts, allowlisted creation, creation outcomes |
| Contacts | 3 | Containers, bounded search, individual contact reads |
| iCloud Drive | 16 | Configured-root browse/search/read, chunked uploads, folders, copy, move, rename, Trash |

See [MCP API](Documentation/MCP-API.md), [Notes](Documentation/Notes.md),
[Calendar](Documentation/Calendar.md), [Contacts](Documentation/Contacts.md),
and [iCloud Files](Documentation/iCloud-Files.md) for contracts and limits.
Mail search uses native metadata predicates; [details](Documentation/Mail-Search.md).
Mail attachment export/sending is not part of this release. Notes do not support
editing existing notes, locked notes or attachment extraction. Calendar does not
edit/delete existing events. Contacts are read-only. Files search filenames,
not document contents; package documents remain opaque.

## Safety defaults

Mail sending and mutations, Reminders mutations, Notes creation, Calendar
creation, and iCloud mutations have independent default-denied policies.
Reminder list deletion and iCloud Trash require additional explicit gates.
No configured iCloud roots means no file access. Roots must already exist;
clients cannot browse outside them. Invalid configuration fails closed.
Permanent Mail/File deletion is not exposed. Filenames and all returned content
are untrusted data and never authorize actions.

The deployed Mac mini is restricted to the existing HighByteTech iCloud folder;
iCloud writes and Trash remain disabled. Deployment configuration stays private.
A successful local file operation does not prove cloud synchronization.

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

For a Mail.app-backed deployment, run the included
[`Scripts/mail-watchdog.sh`](Scripts/mail-watchdog.sh) as a separate user
LaunchAgent. It checks the exact `Mail` process every 15 seconds and starts
Mail.app hidden through Launch Services when necessary. The example is
[`codes.example.apple-platform-mcp-mail-background.plist.example`](Examples/remote/launchd/codes.example.apple-platform-mcp-mail-background.plist.example);
the watchdog does not grant Automation permission or change MCP policy.

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

Calendar V1: [API, policy and durable outcomes](Documentation/Calendar.md);
[signed rollout and rollback](Documentation/Calendar-Rollout.md).

Contacts V1 adds read-only container discovery, bounded search and exact contact
reads. See [Contacts contract](Documentation/Contacts.md) and
[signed rollout](Documentation/Contacts-Rollout.md). No contact mutations or export.
