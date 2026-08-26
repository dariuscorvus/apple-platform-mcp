# Compatibility and test status

## Local verification

The project is built with Xcode 26.6, macOS SDK 26.5, Swift 6, and an arm64 Debug destination.

Verified locally:

- XcodeGen project regeneration
- native app-bundle build
- unit tests
- native targeted Reminders tests and the native suite with the known hanging
  Mail send-contract test excluded
- MCP stdio lifecycle
- MCP SDK in-memory client/server contract
- tool catalog and schemas, including the separately gated Reminders lifecycle
- sanitized body limits
- configuration defaults and policy allowlists
- closed-Mail failure path
- universal Release binary (`arm64` and `x86_64`)
- signed universal archive with Hardened Runtime and Apple Events entitlement
- synthetic fixture pagination, message detail, and attachment-reference tests

## Mail.app matrix

| Fixture | Accounts | Mailboxes | Search | Message read | TCC | Status |
|---|---:|---:|---:|---:|---:|---|
| Synthetic in-memory fixture | verified | verified | verified | verified | n/a | unit/contract tests |
| No Mail.app process | — | — | — | — | — | verified `mailNotRunning` |
| Dedicated iCloud/IMAP fixture | pending | pending | pending | pending | pending | required for v0.1 |
| Dedicated Proton Mail Bridge fixture | pending | pending | pending | pending | pending | required for v0.1 |

Personal mail is not an accepted fixture.

## Performance and reliability

Tool responses include duration metadata. A dedicated fixture is still required to measure account, mailbox, search, and message-body budgets and to evaluate Apple Event hangs. The current single-process spike does not claim cancellation of a synchronous Apple Event; a worker process remains the fallback if measurements require isolation.

## Reminders matrix

The Reminders adapter is compiled with the existing macOS 13 deployment
target. It calls `requestFullAccessToReminders` on macOS 14+ and the
deprecated-but-available `requestAccess(to: .reminder)` path on macOS 13.
Authorization states are normalized before they reach the service or MCP
layer. The current host is macOS 26.6.2; a dedicated macOS 13 runtime/TCC
pass is still required before claiming production reliability on macOS 13.

| Fixture | Reads | Lifecycle writes | Reference restart | Permission | Status |
|---|---:|---:|---:|---:|---|
| In-memory repository | verified | verified | deterministic fake references | normalized fake states | unit/contract tests |
| Current macOS 26.6.2 iCloud fixture | verified | create/update/complete/delete and list CRUD verified | save/update/restart verified | Full Access granted | isolated live stdio smoke passed; cleanup verified |
| Dedicated macOS 13 Reminders fixture | pending | pending | pending | pending | release gate |
| Separate macOS 14+ fixture | pending | pending | pending | pending | compatibility expansion |

The current-host smoke used only a freshly named list and Reminder, selected
one explicit source-list reference, and deleted only those fresh objects.
It does not establish cross-device/full-sync reference stability. Due-date and
recurrence writes remain deferred to their dedicated hardening slices.

## Client matrix

The protocol contract is tested with the official MCP Swift SDK client over `InMemoryTransport`. The stdio smoke test also completes initialization, tool discovery, server info, and the closed-Mail failure path against the app-bundle executable. A desktop MCP host and a CLI/coding host still need manual verification against the app-bundle executable.
