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

## Remote gateway boundary

The optional remote deployment adds a separate TypeScript gateway. It is not a
second mail adapter:

- the gateway binds to `127.0.0.1` by default and starts the signed Swift
  executable over stdio
- Cloudflare Tunnel provides the public TLS connection without opening an
  inbound router port
- Cloudflare Access authenticates the remote user; the gateway independently
  verifies the `Cf-Access-Jwt-Assertion` issuer, audience, and optional email
- the gateway accepts MCP requests only at the configured exact path and can
  enforce an explicit browser `Origin` allowlist
- capability-token mode is intended for private testing only. The token is
  placed in the endpoint path and must not be exposed as a public deployment
  substitute for OAuth

Remote access does not change the local permission boundary. Mail.app,
Automation approval, the signed app bundle, and the configured read-only policy
must all remain on the Mac running the gateway.

## Untrusted content

Message bodies and HTML are data. They cannot alter tool selection, policy, recipients, or configuration. HTML active elements and URL-bearing attributes are removed before output.

## Logging

The stdio channel is reserved for MCP protocol messages. Startup failures go to `stderr`. The implementation does not log message bodies, subjects, recipients, search text, attachment contents, or Apple Event payloads.

## Write roadmap

Drafts and sending are not implemented in this release. Any future send capability must use a short-lived, one-time Prepare/Confirm action tied to a content hash and a fresh draft read. Direct send tools are not part of the API.
