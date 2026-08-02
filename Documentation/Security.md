# Security model

The server mediates access to local mail. The default is read-only.

## Boundaries

- Mail.app is accessed through ScriptingBridge and Apple Events.
- All bridge calls stay behind `ScriptingBridgeMailRepository`.
- The repository actor serializes bridge access.
- Mail references are versioned and opaque to clients.
- Reference and cursor values are bound to their versioned wire format; malformed or mismatched values fail closed.
- Account and mailbox allowlists are enforced in the application service.
- Search results and message bodies have server-side limits.
- Attachments are returned as metadata only.
- No Mail database, browser automation, screen scraping, Accessibility, or provider credential handling is used.

## Untrusted content

Message bodies and HTML are data. They cannot alter tool selection, policy, recipients, or configuration. HTML active elements and URL-bearing attributes are removed before output.

## Logging

The stdio channel is reserved for MCP protocol messages. Startup failures go to `stderr`. The implementation does not log message bodies, subjects, recipients, search text, attachment contents, or Apple Event payloads.

## Write roadmap

Drafts and sending are not implemented in this release. Any future send capability must use a short-lived, one-time Prepare/Confirm action tied to a content hash and a fresh draft read. Direct send tools are not part of the API.
