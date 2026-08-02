# Compatibility and test status

## Local verification

The project is built with Xcode 26.6, macOS SDK 26.5, Swift 6, and an arm64 Debug destination.

Verified locally:

- XcodeGen project regeneration
- native app-bundle build
- unit tests
- MCP stdio lifecycle
- MCP SDK in-memory client/server contract
- read-only tool catalog and schemas
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

## Client matrix

The protocol contract is tested with the official MCP Swift SDK client over `InMemoryTransport`. The stdio smoke test also completes initialization, tool discovery, server info, and the closed-Mail failure path against the app-bundle executable. A desktop MCP host and a CLI/coding host still need manual verification against the app-bundle executable.
