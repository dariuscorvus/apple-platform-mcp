# Permissions and packaging

The primary runtime is a background macOS application bundle that exposes its embedded executable through `stdio`.

Executable path inside a Debug build:

```text
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp
```

The bundle contains:

- `NSAppleEventsUsageDescription`
- `NSRemindersFullAccessUsageDescription` for the explicit Reminders lifecycle
- `NSRemindersUsageDescription` for the macOS 13 EventKit fallback
- `com.apple.security.automation.apple-events`
- no Accessibility entitlement
- no Full Disk Access requirement

The Release configuration enables Hardened Runtime. `doctor` fails a signed distribution build that lacks Hardened Runtime or the Apple Events entitlement.

The adapter performs a non-prompting Apple Events permission check before reading Mail. An MCP request never opens a TCC consent prompt. Use `apple-platform-mcp .../apple-platform-mcp doctor` to inspect state without reading account or message data.

The explicit Mail setup command is the only prompt-capable Mail path:

```sh
apple-platform-mcp doctor --request-automation
```

It sends one harmless request for Mail.app's name. macOS then shows the Automation consent prompt for the signed `Apple Platform MCP` host. Allow Mail for that host, rerun the command, and require a `pass` result before starting the MCP server.

Reminders has a separate explicit setup command:

```sh
apple-platform-mcp doctor --request-reminders
```

The command requests Reminders Full Access through EventKit and then prints a
normalized status report. No Reminders MCP tool requests permission implicitly,
including lifecycle writes. A `write_only`, denied, restricted, or
not-yet-granted state cannot be used for reads or writes; the server requires
Full Access.

The command can exit non-zero because the independent Mail Automation check is
also part of the report. For Reminders setup, inspect the JSON and require the
`reminder_permission` check to be `pass`. If macOS displays a prompt, allow
**Apple Platform MCP** under Reminders before starting the server.

Reminders writes remain default-denied after TCC approval. They require a
separate explicit local configuration (`reminder_mutation_mode=allowed`), and
list deletion additionally requires `reminder_list_delete_enabled=true`. See
[Reminders.md](Reminders.md) for the isolated three-stage smoke procedure.

## Development

Unsigned development builds can compile and run the stdio protocol, but they are not distribution-ready. TCC behavior must be verified with a signed build under a dedicated macOS test account.

The signing identity is part of the macOS privacy identity. Do not install a
Debug or ad-hoc build as the long-running host service: its cdhash-based
designated requirement changes with every rebuild, so macOS can treat the
updated app as a new Reminders client. Host upgrades must use Release builds
signed by the same stable Developer ID identity.

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
