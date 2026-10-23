# Mail attachments implementation plan

Status: TASK-019 in progress; exact attachment identity guard and static dictionary inspection implemented. Runtime feasibility and TASK-020–022 remain pending. See [feasibility evidence](Mail-Attachments-Evidence.md).
Date: 2026-10-17

## Goal

Download individual received attachments, attach explicitly selected files to
unsent drafts, inspect/remove attachments, and send with the existing Mail policy.
Mail.app remains the account and credential owner. Implement in TASK-019–022 order.

## Repository baseline

- `DomainModels.swift` and `ScriptingBridgeMailRepository.swift` already expose
  opaque attachment metadata through message detail, without attachment contents.
- `Mail.sdef` declares received-attachment save and outgoing rich-text attachments.
  These declarations are leads for a prototype, not proof of working runtime behavior.
- `mail_create_draft` currently returns acceptance/account/from/subject, without a
  durable draft reference. Add/remove/read/send of an existing draft needs an exact,
  restart-safe identity strategy; never recover drafts by subject or recipient search.
- `mail_send_message` and `mail_create_draft` currently accept text/recipients only.
  Existing account/identity validation, send_mode and mutation_mode must remain effective.
- Both stdio and authenticated Streamable HTTP must expose the same contracts.

## Stage 1 — Feasibility and contract (TASK-019)

Prototype received-file save, attachment availability/download state, outgoing-file
insertion, saved-draft resolution after restart and attachment removal. Use synthetic
fixtures. The operator explicitly authorized self-send to user@example.com on
2026-10-17 instead of requiring a dedicated test account; restrict operations
to those fixtures and retain journals. Verify current Apple documentation and
installed dictionary during implementation. Measure Apple Event deadlines and behavior
when the attachment is not cached; return bounded unavailable/timeout errors.

Resolve whether exact draft operations are reliable. If not, document the limitation
and choose a supported contract before promising editing or send-existing-draft.
Define cleanup/retention, quotas, MIME versus observed content, provider limits and
base64/MIME expansion. Proposed starting limits: 10 files, 20 MiB per file, 25 MiB raw
total; configurable, with lower account/provider limits taking precedence. These are
product defaults to validate, not verified Mail/provider limits.

## Stage 2 — Download and private file store (TASK-020)

Proposed tool: `mail_download_attachment(attachment_id, idempotency_key)`.
Resolve the exact parent message/account/mailbox and enforce allowlists at each use.
Reject stale/fabricated references and index-based fallback when identity is uncertain.
Store atomically in a private configured directory, mode 0700/0600, without overwrite,
path traversal, symlink escapes or client-selected arbitrary destination paths.

Return an opaque file reference, original/safe filename, observed MIME type, actual
byte count, SHA-256 and availability/expiry. Return a local path only on an explicitly
local contract. Repeated requests reuse a verified result; interrupted saves do not
leave downloadable partial files. Enforce actual byte limits during export where the
backend allows it; otherwise isolate staging and explicitly document that limitation.
Keep metadata-only message reads free of implicit attachment export.

## Stage 3 — Draft attachments and send (TASK-021)

Extend `mail_create_draft` with optional `attachment_ids` referring to staged files;
text-only requests remain compatible. Subject to Stage 1, add exact draft-reference
operations to inspect, add and remove attachments and send the reviewed draft.
Specify final tool names/schema after the feasibility result, not as existing tools.
Offer the same staged-file input on `mail_send_message` if direct-send attachment
support is reliable; preserve its independent send gate.

Only accept owned staged files or explicitly configured import roots with canonical,
regular-file validation. Never accept arbitrary server paths, URLs or email-supplied
paths. Snapshot bytes and hashes before Mail sees them so later file changes cannot
change the selected attachment. Check all files before creating/sending and read back
attachments after draft save. Missing, duplicate, unavailable or mismatched attachments
must not silently produce a text-only send. Inspect/remove of draft attachments uses
existing mutation policy; file export/import has independent default-denied gates.

Persist idempotency for draft creation/attachment changes/send. Bind keys to the full
request including account, recipients and attachment hashes. After ambiguous Apple
Events or transport disconnects, return an unknown outcome and reconcile without
blind resend. Mail acceptance must never be described as recipient delivery. Existing
confirmation_required behavior must not be bypassed. Before send, verify the reviewed
revision including recipients/text/attachments, or fail if the draft has changed.

## Stage 4 — Client transfer and acceptance (TASK-022)

A path on the Mac mini is not a downloadable ChatGPT artifact, and a client upload is
not automatically accessible to this server. Verify the connected client's supported
file/resource mechanism before choosing upload/download transport. Local export can
ship with its clearly scoped contract; remote download/upload stays incomplete until
actual client acceptance. Do not promise arbitrary MCP resource or file-link support.

Any transfer must reuse authenticated access, opaque expiring file references, bounds,
cleanup and no public static directory, bearer URL or unauthenticated file route.
Separate local staged-file reuse (received attachment -> outgoing draft) from client
upload. Local workflow does not depend on remote file transfer.

## Verification and rollout

- Synthetic tests: allowlists, invalid/stale refs, metadata-only reads, malformed
  filenames, traversal/symlinks, collisions, partial writes, quotas and expiry.
- Draft/send tests: account/from validation, all policy modes, missing/changed files,
  attachment order/duplicates/removal, saved draft restart, reviewed-revision mismatch,
  idempotent retries and ambiguous outcomes after disconnect/restart.
- Both transports: schema validation, unchanged text-only calls and denied defaults.
- Isolated signed Mail.app acceptance: synthetic file hashes after export, draft
  attachment readback/removal, restart and cleanup. Do not use personal mailbox data.
- Send acceptance requires a deliberately selected test sender/recipient and explicit
  live-send authorization. The operator authorized synthetic self-send to user@example.com
  on 2026-10-17; this does not authorize unrelated recipients or routine production sends.
- Build/sign candidate, backup and rollback, isolated smoke before activation; retain
  durable journals on rollback. Record actual client download/upload evidence separately.
- Update MCP API, security/config documentation, examples and deployment runbook.
  Complete tasks only for the evidence actually obtained; keep pending client gates open.

## Out of scope

Bulk export, automatic forwarding, automatic opening/execution, archive unpacking,
public file hosting, private Mail database access and bypassing OS consent/policies.
