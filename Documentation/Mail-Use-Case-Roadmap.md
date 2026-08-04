# Mail use-case roadmap

Status: active

Date: 2026-08-05

Tracking: [GitHub issue #10](https://github.com/dariuscorvus/apple-platform-mcp/issues/10)

## Objective

Make the existing read-only Mail tools useful on realistic Mail.app accounts without weakening the privacy, signing, policy, or read-only boundaries.

Distribution and remote access are tracked separately in [issue #1](https://github.com/dariuscorvus/apple-platform-mcp/issues/1). A transport can be available while the underlying Mail operation still exceeds the client deadline.

## Verified baseline

The installed signed server and repository behavior were investigated after repeated unread-search timeouts. Only elapsed times and aggregate mailbox counts were retained; message content and metadata were not copied into the repository or issues.

| Operation | Observed result |
| --- | --- |
| Unscoped unread search with a limit of 10 | Timed out after 300 seconds |
| Inbox-scoped unread search with a limit of 10 | Completed in approximately 52 seconds |
| Account listing | Approximately 31 seconds |
| Mailbox listing with counts | Approximately 33 seconds |
| External All Mail `whose read status is false` probe | Exceeded 120 seconds |

The current ScriptingBridge repository traverses every enabled account and collected mailbox when no mailbox references are supplied. It evaluates messages individually, stops only after enough matching results exist, and encodes pagination as a matching-result offset. Overlapping Mail views can therefore repeat work.

These measurements are diagnostic evidence, not the synthetic-fixture acceptance evidence required by ADR-0001.

## Delivery plan

### A. Measure and enforce bounds

Tracking: [issue #6](https://github.com/dariuscorvus/apple-platform-mcp/issues/6)

- Create privacy-safe synthetic small and large Mail.app fixtures.
- Measure Automation readiness, enumeration, candidate retrieval, filtering, property reads, and response encoding separately.
- Compare current traversal, Apple Event predicates, bounded newest-first traversal, and batched property retrieval where supported.
- Add non-sensitive stage timings and inspected-item counters.
- Define per-operation deadlines and actionable bounded failures.

Exit condition: a measured strategy and latency budget exist. No optimization is selected from assumptions.

### B. Make common triage workflows explicit

Tracking: [issue #7](https://github.com/dariuscorvus/apple-platform-mcp/issues/7)

- Provide Inbox and unread semantics that do not require prior opaque mailbox discovery.
- Resolve the canonical Inbox through mailbox role rather than localized display names.
- Avoid implicit traversal of All Mail, labels, Sent, Drafts, Trash, and Junk.
- Define deterministic newest-first ordering.
- Preserve explicit account and mailbox scopes and policy allowlists.

Exit condition: “ten unread Inbox messages” meets the budget selected in phase A.

### C. Remove repeated work

Tracking: [issue #8](https://github.com/dariuscorvus/apple-platform-mcp/issues/8)

- Replace offset rescans with measured, resumable seek pagination.
- Minimize listing and search property projection.
- Defer message source, body, and attachment detail to `mail_get_message`.
- Stop candidate inspection once a page and continuation decision are known.

Exit condition: later pages do not rescan earlier results and measured Apple Event work decreases.

### D. Make the backend Go/No-Go decision

Tracking: [issue #9](https://github.com/dariuscorvus/apple-platform-mcp/issues/9)

Decide from benchmark evidence whether to:

1. retain ScriptingBridge for all read operations;
2. retain it for discovery and targeted reads while adding a provider-neutral IMAP/JMAP search adapter;
3. isolate it in a supervised worker with strict recovery; or
4. intentionally restrict broad archive search when no supported backend meets the budget.

Direct reads from Mail.app’s private database remain out of scope. MailKit is not assumed to provide general mailbox access. Proton Mail Bridge compatibility must be tested explicitly.

Exit condition: archive-wide search is either supported within a measured budget or reported as intentionally limited, and ADR-0001 is promoted, amended, or superseded.

## Cross-cutting requirements

- Preserve read-only mode and the existing five-tool allowlist until a separate security decision changes it.
- Do not add Accessibility, Computer Use, screen scraping, or private Mail database access.
- Keep Mail.app as credential owner for the ScriptingBridge path.
- Keep account and mailbox allowlists, opaque references, cursor binding, body limits, sanitization, and untrusted-content handling fail-closed.
- Health checks must not launch Mail.app or read mailbox contents.
- Test timeout and cancellation behavior at transport, SDK, handler, and Apple Event boundaries.
- Use synthetic fixtures for automated tests; personal mailbox content must never enter logs or artifacts.
- Keep local stdio and Streamable HTTP semantics identical.

## Completion criteria

- Common Inbox unread and newest listing is responsive and requires no mailbox-ID lookup.
- Every expensive operation has a documented budget and actionable bounded failure.
- Pagination does not restart the entire search.
- Capability reporting distinguishes fast scoped workflows from broad archive search.
- Phase 0 evidence and ADR status reflect measured behavior.
