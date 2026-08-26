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

The repository implements Mail.app-backed tools and a full policy-controlled
Reminders lifecycle. Reading is enabled by default; Mail sending, Mail
mutations, and Reminders mutations are separately denied by default. Mail and
Reminders content is untrusted data and never authorizes another tool call or
changes policy. The Reminders lifecycle is current on the verified development
host; macOS 13 runtime/TCC coverage remains a release compatibility gate.

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

## Reminders lifecycle

Reminders requires explicit Full Access. The MCP server never opens a
permission prompt; run `apple-platform-mcp doctor --request-reminders` during
setup. Every read and write uses opaque, versioned `rr1_` references. The
adapter resolves them exactly and never searches by title, date, list scan, or
external identifier.

### `reminder_list_lists`

Takes no arguments. Returns `id`, `name`, optional `source_name`, and
read/write capability metadata. `id` is opaque and must be passed back
unchanged.

### `reminder_list_reminders`

Input:

```json
{
  "list_id": "rr1_opaque-list-reference",
  "completed": false,
  "due_after": "2026-08-26T00:00:00Z",
  "due_before": "2026-09-01T00:00:00Z",
  "limit": 20
}
```

Only `list_id` is required. `completed`, `due_after`, and
`due_before` are optional filters; due boundaries are exclusive ISO-8601
date-times. `limit` is positive and is clamped server-side to the configured
`max_results` maximum. Results contain opaque reminder/list references,
title, notes, priority, completion state/date, and representable due/recurrence
values. Timed due values require an explicit `time_zone`; all-day values use
the explicit `all_day` shape. A timed due value without an explicit time zone
is rejected as unsupported.

### `reminder_get_reminder`

Input:

```json
{
  "reminder_id": "rr1_opaque-reminder-reference"
}
```

`reminder_id` is required and must be returned unchanged by
`reminder_list_reminders`. The adapter resolves it with the direct EventKit
item identifier only, validates calendar/source/external anchors exactly, and
returns the same normalized item type as the list tool. No title, date, or
external-identifier search fallback is used.

Reminders permission, stale-reference, and unsupported-value failures use
normalized error envelopes; raw EventKit errors and Apple identifiers are not
returned.

### `reminder_create_reminder`

Input requires `list_id`, non-empty `title`, and `idempotency_key`. Optional
`notes` and `priority` (0 through 9) are accepted. The target list must be an
opaque current reference with `can_write=true`; the server does not choose a
list implicitly.

### `reminder_update_reminder`

Input requires `reminder_id` and `idempotency_key`, plus at least one patch
field: optional `list_id`, `title`, `notes`, or `priority`. Omitted fields are
unchanged. `notes: null` clears notes; the response normalizes EventKit's empty
cleared value to absent `notes`. Due and recurrence writes are not exposed.

### `reminder_complete_reminder`

Input requires `reminder_id` and `idempotency_key`. Completion is an exact,
idempotent mutation of the selected writable Reminder.

### `reminder_delete_reminder`

Input requires `reminder_id` and `idempotency_key`. It is permanently
destructive and is annotated as such in tool discovery. No unreferenced
Reminder can be deleted.

### `reminder_create_list`

Input requires an explicit writable `source_list_id`, a non-empty `name`, and
an `idempotency_key`. The source-list reference selects only its EventKit
source; the existing source list is not modified. The adapter never guesses a
default account/source.

### `reminder_update_list`

Input requires `list_id`, non-empty `name`, and `idempotency_key`. It renames
only an exactly resolved mutable list.

### `reminder_delete_list`

Input requires `list_id` and `idempotency_key`. It is permanently destructive,
requires the separate list-delete policy gate, and refuses any non-empty or
immutable list before EventKit removal.

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
  "mutation_mode": "denied",
  "reminder_mutation_mode": "denied",
  "reminder_list_delete_enabled": false
}
```

`mutation_mode` accepts `denied`, `allowed`, and `confirmation_required`.
`confirmation_required` is intentionally fail-closed until an explicit
confirmation boundary is implemented. The server never infers confirmation
from message content or a natural-language request alone.

`reminder_mutation_mode` is independent of both Mail policy modes. Only
`allowed` enables Reminder create/update/complete/delete and list
create/update. `reminder_delete_list` also requires
`reminder_list_delete_enabled=true`. Each Reminder mutation requires an
operation-specific idempotency key. The bounded store coalesces and returns
same-process retries, but does not promise persistence across a restart.

Use `serve --transport stdio --config /absolute/path/config.json` for an
explicit isolated configuration; ordinary starts continue to load the normal
optional configuration file and therefore remain default-denied.

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
