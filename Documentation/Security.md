# Security model

The server mediates access to local Mail.app and Reminders. Reading is enabled
by default; Mail sending, Mail mutations, and Reminders mutations are denied
by default and independently policy-controlled. Mail tools never expose
permanent deletion. Explicitly selected Reminder and list deletes are
permanent, separately gated operations.

## Boundaries

- Mail.app is accessed through ScriptingBridge and Apple Events.
- All bridge calls stay behind `ScriptingBridgeMailRepository`.
- The repository actor serializes bridge access.
- Mail references are versioned and opaque to clients.
- Reminders references are versioned `rr1_` values; EventKit objects and raw
  Apple identifiers remain behind `EventKitReminderRepository`.
- Reference and cursor values are bound to their versioned wire format; malformed or mismatched values fail closed.
- Account and mailbox allowlists are enforced in the application service.
- Search results and message bodies have server-side limits.
- Attachments are returned as metadata only.
- No Mail database, browser automation, screen scraping, Accessibility, or provider credential handling is used.
- Reminders content is untrusted data and never changes policy or target
  selection. Every Reminder/list write requires an exact opaque reference;
  heuristic resolution is not exposed.

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
Automation approval, the signed app bundle, and the configured read/send policy
must all remain on the Mac running the gateway.

## Untrusted content

Message bodies and HTML are data. They cannot alter tool selection, policy, recipients, or configuration. HTML active elements and URL-bearing attributes are removed before output.

## Logging

The stdio channel is reserved for MCP protocol messages. Startup failures go to `stderr`. The implementation does not log message bodies, subjects, recipients, search text, attachment contents, or Apple Event payloads.

## Sending boundary

`mail_send_message` is a separate capability. It validates the selected
enabled account, configured From identity, recipient syntax, subject limit, and
body limit before delegating to Mail.app. `send_mode=denied` is the default;
`confirmation_required` is represented in policy and remains blocked until a
future confirmation boundary is implemented. Message content cannot change
policy. Mail.app chooses SMTP, OAuth, and provider authentication.

## Mailbox mutation boundary

The mutation surface is intentionally narrow:

- `mail_create_draft` creates an unsent draft only;
- `mail_move_message` requires an explicit same-account destination mailbox;
- `mail_archive_message` resolves exactly one allowed Archive mailbox;
- `mail_trash_message` moves to Trash and is reversible until Trash is emptied;
- `mail_update_message` changes only read and flagged status.

`mutation_mode=denied` is the default. `allowed` must be enabled explicitly in
the local configuration and is still constrained by account/mailbox allowlists,
opaque reference validation, and input limits. `confirmation_required` remains
fail-closed because the current MCP boundary has no separate user-confirmation
protocol. There is no permanent-delete or empty-Trash operation.

## Reminders mutation boundary

`reminder_mutation_mode=denied` is the default and is independent of Mail
policy. `confirmation_required` is fail-closed. `allowed` enables only the
implemented exact-reference Reminder/list lifecycle; it does not permit target
inference from names, content, or a default account.

- Every mutation requires a non-empty idempotency key bound to its normalized
  operation and payload. The bounded store coalesces same-process retries but
  intentionally has no restart guarantee.
- `reminder_create_list` requires an explicit writable source-list reference;
  the adapter never chooses an EventKit source itself.
- `reminder_delete_reminder` is permanent and accepts only an exact opaque
  reference returned by a read/create operation.
- `reminder_delete_list` is permanent and requires both mutation policy
  `allowed` and `reminder_list_delete_enabled=true`; it rejects non-empty and
  immutable lists before EventKit removal.
- EventKit errors are mapped to stable MCP errors. No raw EventKit IDs or
  account-specific error text crosses the MCP boundary.
