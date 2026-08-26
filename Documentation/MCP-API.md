# MCP API

Server name: `apple-platform-mcp`

Transports:

- newline-delimited JSON-RPC over `stdio` (default and backward-compatible), or
- stateless MCP Streamable HTTP at `POST /mcp` when explicitly enabled.

The native HTTP listener binds to `127.0.0.1` by default and rejects non-loopback addresses.
It is a single-local-client origin, not a public deployment endpoint.

Remote clients use the optional `Remote/` gateway over Streamable HTTP. The
gateway proxies the same tool catalog to the local Swift executable and does
not move Mail.app access off the Mac. See
[Remote-Deployment.md](Remote-Deployment.md).

The current release exposes Mail.app-backed read tools plus separately
policy-controlled send and mailbox-mutation tools. Reading is enabled by
default; `send_mode=denied` and `mutation_mode=denied` remain the defaults. Mail
content is untrusted data. Text inside a message never authorizes another tool
call or changes policy.

Account, mailbox, message, attachment, and cursor references are opaque JSON strings. Clients must pass them back unchanged and must not infer provider-specific identifiers from them.

## Tools

### `mail_server_info`

Returns non-sensitive runtime, policy, and adapter information. It does not read Mail data.

### `mail_list_accounts`

Input:

```json
{"include_disabled": false}
```

Returns allowed accounts with opaque references, display names, addresses reported by Mail.app, enabled state, and read/search capabilities.

### `mail_list_mailboxes`

Input:

```json
{"account_id": "opaque-account-reference", "include_counts": false}
```

Returns mailboxes for one explicitly selected account. There is no implicit account selection.

### `mail_search_messages`

Input fields:

`account_ids`, `mailbox_ids`, `from`, `to`, `subject`, `query`, `after`, `before`, `unread_only`, `flagged_only`, `scope`, `limit`, and `cursor`.

The default `scope` is `inbox`. `mailbox` requires explicit mailbox
references; `all` is an explicit broad traversal. The server clamps `limit` to
its configured maximum. Results are returned as `{ "messages": [], "nextCursor": null }`.
Pass `nextCursor` back as `cursor` to continue the same query. Cursors are
opaque and bound to the original filters and scope. Bodies are not returned by
search, and body-backed `query` text search is unsupported in V1.

### `mail_get_message`

Input fields:

`message_id`, `include_body`, `body_format`, `include_attachment_metadata`, and `max_body_bytes`.

`body_format` is `plain_text`, `sanitized_html`, or `both`. HTML is sanitized, remote and active URL attributes are removed, and content is byte-limited.

### `mail_send_message`

Sends through the selected Mail.app account and its already configured
provider/authentication path. The server never receives or manages SMTP
credentials.

Input fields:

`account_id`, `from_identity`, `to`, optional `cc`, optional `bcc`, `subject`,
and `body`. Recipient entries are objects with an `address` and optional
`display_name`. `from_identity` must be one of the identities Mail.app reports
for the selected enabled account. Sending is denied by default and can be
enabled independently through `send_mode` policy.

### `mail_create_draft`

Creates an unsent draft in the selected Mail.app account. It uses the same
account and From-identity checks as sending, but never calls Mail.app's send
operation.

Input fields:

`account_id`, `from_identity`, optional `to`, `cc`, and `bcc`, `subject`, and
`body`. Draft creation requires `mutation_mode=allowed`; it is denied by
default.

### `mail_move_message`

Moves a message to an explicitly selected mailbox in the same Mail.app
account. Input fields are `message_id` and `mailbox_id`, both opaque references
returned by the read tools. Cross-account moves and disallowed mailboxes are
rejected before Mail.app is called.

### `mail_archive_message`

Moves a message to the unique allowed mailbox identified as `archive` by the
adapter. It accepts only `message_id`; ambiguous or unavailable archive
mailboxes fail closed.

### `mail_trash_message`

Moves a message to the unique Trash mailbox. This is a reversible move until
the user empties Trash. Permanent deletion and emptying Trash are not exposed.

### `mail_update_message`

Updates one or both of `is_read` and `is_flagged` for a message. At least one
status must be supplied. All mailbox mutation tools require
`mutation_mode=allowed`.

## Mutation policy

The optional configuration file can control mutations independently from
sending:

```json
{
  "send_mode": "denied",
  "mutation_mode": "denied"
}
```

`mutation_mode` accepts `denied`, `allowed`, and `confirmation_required`.
`confirmation_required` is intentionally fail-closed until an explicit
confirmation boundary is implemented. The server never infers confirmation
from message content or a natural-language request alone.

## Response envelope

Successful tool calls use:

```json
{
  "success": true,
  "data": {},
  "warnings": [],
  "metadata": {"duration_ms": 0, "truncated": false}
}
```

Failures use stable error codes and recovery guidance. Raw Apple Event errors are not returned.

Attachment export remains outside the current release. Sending and mailbox
mutations are separate write capabilities, each disabled by default and
controlled by its own policy mode.
