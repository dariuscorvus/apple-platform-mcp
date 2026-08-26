# ADR-0002 — Mail.app as V1 Mail Backend

- **Status:** accepted for V1
- **Date:** 2026-08-25
- **Supersedes:** the provisional backend-reassessment direction in ADR-0001 and the earlier hybrid/IMAP implementation direction tracked by Issues #9, #10, and #13

## Decision

Apple Mail (`Mail.app`) is the sole mail backend and source of truth for V1.
Apple Platform MCP uses the accounts, identities, authentication state, local
mailboxes, and delivery path that are already configured in Mail.app.

- Mail.app owns account configuration and credentials for iCloud, Gmail,
  Exchange, IMAP, and other providers.
- Reading is implemented through ScriptingBridge / Apple Events.
- Sending is implemented through Mail.app / ScriptingBridge; Mail.app chooses
  the configured SMTP/provider and authentication path.
- The public MCP API remains backend-neutral. Clients receive opaque references
  and do not see provider-specific identifiers or credentials.
- Apple Platform MCP does not maintain parallel IMAP or SMTP credentials,
  account configuration, credential stores, OAuth flows, or automatic
  credential discovery.
- Mail.app's private database is out of scope. Accessibility, screen scraping,
  and Computer Use are out of scope.

## Capability boundary

V1 separates capabilities explicitly:

| Capability | V1 policy |
| --- | --- |
| Read accounts, mailboxes, search summaries, and message detail | enabled through Mail.app |
| Send a message | separate capability; explicitly enabled and policy-controlled |
| Delete, move, archive, mark read, flag, draft mutation, or other mailbox mutation | disabled |

Message content is untrusted data. It can never change the send policy or
authorize a mailbox mutation.

Sending is therefore not an implicit consequence of read access, and mailbox
mutations remain disabled even when sending is enabled.

## Search scope and performance

Common agent workflows are first-class V1 targets: newest Inbox messages,
unread Inbox messages, sender/subject filters in Inbox, and one-message reads.
An unscoped search must not implicitly traverse every account, mailbox, and
message. The default search scope is the canonical Inbox for the selected or
otherwise eligible accounts; broader mailbox or archive scopes are explicit.

Newest-first traversal is only used where the Mail.app scripting behavior and
measurements establish that it is correct. A result limit must bound actual
work, not only the response size. Search summaries never require a message
source or body, HTML parsing, or attachment content.

The existing offset cursor may remain for V1 when no reliable ScriptingBridge
positioning primitive is available. It is bound to the complete query and scope
and does not claim snapshot semantics across Mail.app changes.

## IMAP reassessment rule

IMAP is not a V1 component. No IMAP implementation, IMAP repository, protocol
pagination, UID/UIDVALIDITY layer, SMTP client, SMTP credential store, or
provider-specific OAuth/app-password provisioning is added by this decision.

IMAP may be reconsidered only after bounded V1 benchmarks produce measured
capability or performance gaps. The decision tree is:

1. If the important V1 workflows meet their target budgets, keep Mail.app-only
   and do not add IMAP.
2. If only broad archive search is too slow, evaluate an optional protocol-level
   search accelerator for that measured workflow; do not automatically add a
   second complete backend.
3. If core Inbox/detail workflows are unusable, reopen the architecture with a
   new threat model, credential-ownership decision, and migration plan.

Historical IMAP proposals and measurements remain in their issues and prior
artifacts, but they are paused and are not immediate implementation work.

## Consequences

Mail.app's configured account and delivery environment is reused with minimal
credential surface and a stable local permission boundary. In exchange, V1
accepts Mail.app/ScriptingBridge performance and capability limits, especially
for broad archive searches, and reports those limits rather than silently
falling back to a second protocol backend.

This ADR is intentionally scoped to the V1 backend and capability boundary; it
is not a general Mail.app architecture document.
