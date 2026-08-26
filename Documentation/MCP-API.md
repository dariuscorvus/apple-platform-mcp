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

The current release exposes Mail.app-backed read tools plus a separately
policy-controlled send tool. Mailbox mutations remain disabled. Mail content is
untrusted data. Text inside a message never authorizes another tool call or
changes policy.

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

Draft mutation, moving, deleting, archiving, marking read, flagging, and
attachment export are outside the current release. Sending is the only V1
write capability and remains separately policy-controlled.
