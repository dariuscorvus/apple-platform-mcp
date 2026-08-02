# ADR-0001 — Phase 0 ScriptingBridge decision

Status: pending fixture validation

Date: 2026-08-02

## Context

The project needs a local, provider-neutral read-only path into Mail.app. The approved architecture excludes Computer Use, Accessibility, direct Mail database access, browser automation, and provider-specific credential handling.

## Decision

Keep ScriptingBridge over Apple Events as the Phase 0 adapter and expose it only through the domain repository protocol. Keep the server read-only. Package the stdio executable inside a background macOS application bundle so TCC and signing have a stable identity.

The decision is not yet a production Go. Accounts, mailboxes, bounded search, message normalization, signed TCC onboarding, timing, and Proton Mail Bridge still require a dedicated synthetic fixture.

## Evidence

- The generated Mail.app scripting definition compiles into the Xcode target.
- The arm64 app-bundle build passes.
- The stdio handshake and read-only tool catalog pass.
- The SDK in-memory contract test passes.
- The Release app builds as a universal `arm64/x86_64` binary.
- A temporary Developer ID archive passes strict code-signature verification with Hardened Runtime and Apple Events entitlement.
- The adapter fails closed when Mail.app is not running.
- The adapter performs a non-prompting Automation permission check.

## Exit conditions

Promote the adapter only if a signed test build can reliably list accounts and mailboxes, search bounded fixtures, normalize a message, complete TCC onboarding, and stay within measured time budgets. Reassess the backend or isolate it in a worker if Apple Events hang or cannot be cancelled safely.
