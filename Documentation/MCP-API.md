# MCP API

Server name: `apple-platform-mcp`

Transport: newline-delimited JSON-RPC over `stdio`.

The current release exposes read-only tools only. Mail content is untrusted data. Text inside a message never authorizes another tool call or changes policy.

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

`account_ids`, `mailbox_ids`, `from`, `to`, `subject`, `query`, `after`, `before`, `unread_only`, `flagged_only`, `limit`, and `cursor`.

The server clamps `limit` to its configured maximum. Results are returned as `{ "messages": [], "nextCursor": null }`. Pass `nextCursor` back as `cursor` to continue the same query. Cursors are opaque and bound to the original filters. Bodies are not returned by search.

### `mail_get_message`

Input fields:

`message_id`, `include_body`, `body_format`, `include_attachment_metadata`, and `max_body_bytes`.

`body_format` is `plain_text`, `sanitized_html`, or `both`. HTML is sanitized, remote and active URL attributes are removed, and content is byte-limited.

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

Write tools, drafts, sending, moving, deleting, and attachment export are outside the current release.
