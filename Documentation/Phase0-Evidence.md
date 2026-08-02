# Phase 0 Evidence

Status: pending. The repository and read-only stdio spike are runnable. A production Go decision still requires a dedicated Mail.app fixture, TCC validation, timing measurements, and notarization.

Date: 2026-08-02

## Scope

Phase 0 covers the first MCP server, the Mail.app ScriptingBridge feasibility spike, the read-only policy boundary, and the Apple Events permission contract.

The project does not use Computer Use, Accessibility, screen scraping, GUI automation, the Mail database, MailKit as a mailbox backend, or provider-specific APIs.

## Repository shape

- `ApplePlatformMCP.xcodeproj` is the native Xcode project.
- `project.yml` is the XcodeGen source of truth.
- `ApplePlatformMCPKit` is a static library target. The final stdio executable is self-contained.
- `apple-platform-mcp.app` is a background application bundle containing the stdio executable at `Contents/MacOS/apple-platform-mcp`.
- `ApplePlatformMCPTests` is the unit test target.
- The official MCP Swift SDK is pinned to `0.12.1` in `Package.resolved`.
- `Documentation/Mail.sdef`, `Mail.h`, and `Mail.m` are generated from the installed Mail.app scripting definition with `Scripts/generate-mail-bridge.sh`, `sdef`, and `sdp`.

All Mail automation calls are isolated in the serial `ScriptingBridgeMailRepository` actor. The adapter checks that Mail.app is running and performs a non-prompting Apple Events permission check before reading data. An MCP request never opens a TCC consent prompt.

## Verified locally

- [x] XcodeGen regenerated the project from `project.yml`.
- [x] The arm64 Debug build passed with Xcode 26.6 and macOS SDK 26.5.
- [x] The Swift unit test target passed.
- [x] The MCP stdio handshake passed with protocol `2025-11-25`.
- [x] The app-bundle `doctor` command reports configuration, Mail/TCC, usage-description, signing, and scope status without reading Mail data.
- [x] `tools/list` returned exactly five read-only tools:
  - `mail_server_info`
  - `mail_list_accounts`
  - `mail_list_mailboxes`
  - `mail_search_messages`
  - `mail_get_message`
- [x] `mail_server_info` returned `read_only` mode with `computer_use: false` and `accessibility: false`.
- [x] Reference encoding, content sanitization, result limits, tool annotations, allowlists, and permission error recovery have unit coverage.
- [x] Synthetic fixture tests cover query-bound pagination, message detail, attachment references, and account policy filtering without personal mailbox data.
- [x] A bounded read-only `mail_list_accounts` probe returned `mailNotRunning` when Mail.app was closed. No account names, addresses, subjects, or message contents were emitted.
- [x] The MCP SDK in-memory client/server contract covers initialization, tool discovery, input schema shape, and a diagnostic tool call.
- [x] The Release app builds as a universal `arm64/x86_64` binary. Notarization remains pending.
- [x] The Release configuration enables Hardened Runtime and carries the Apple Events entitlement. Notarization remains pending.
- [x] A universal Developer ID archive passed `codesign --verify --deep --strict`; `doctor` reports Hardened Runtime and the Apple Events entitlement.

The test target emits linker warnings because the Xcode 26 XCTest and Testing runtimes declare macOS 14 as their minimum while the application target currently declares macOS 13. The test command still exits successfully. The minimum supported macOS version remains an open release decision.

## Pending evidence

- [ ] Run the signed executable with Mail.app running under a dedicated macOS test account.
- [ ] Verify the first-run TCC prompt and the recovery path after denial.
- [ ] List accounts and mailboxes through Apple Events without logging their contents.
- [ ] Search a bounded fixture mailbox and read a bounded fixture message body.
- [ ] Measure small and large mailbox behavior and enforce an operation timeout.
- [ ] Repeat the fixture with Proton Mail Bridge.
- [x] Verify a universal arm64/x86_64 release build.
- [x] Verify the signed distribution identity and Hardened Runtime entitlements locally.
- [ ] Notarize and staple a release artifact.

## Go / No-Go

Current result: **PENDING**.

The code supports a provisional Go only after the pending fixture, TCC, timing, and notarization checks pass. A No-Go or backend reassessment is required if Apple Events hang without a controllable budget, message references cannot be resolved within a Mail session, or bounded searches require unacceptable full-mailbox scans.

The next test must use synthetic mail data. Personal mailbox contents must not enter test logs or evidence files.
