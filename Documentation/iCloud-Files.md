# Configured iCloud Drive files

The `icloud_` tools manage ordinary files and folders in explicitly configured
folders belonging to the **server Mac's macOS account**. macOS owns authentication,
downloads and synchronization. The MCP server never accepts Apple ID credentials.
No roots means no file access. Mail, Reminders and Files permissions are independent.

## Configuration

Merge these fields into the local JSON configuration (or use `serve … --config
/absolute/test/config.json`). Configuration changes require a server restart.
Nothing in the implementation enables writes or edits the installed configuration.

```json
{
  "icloud_roots": [
    {
      "id": "project-documents",
      "name": "Project Documents",
      "path": "/Users/your-user/Library/Mobile Documents/com~apple~CloudDocs/MCP Documents"
    }
  ],
  "icloud_mutation_mode": "denied",
  "icloud_trash_enabled": false,
  "icloud_staging_quota_bytes": 1073741824
}
```

The folder must already exist, be readable, and be recognized by Foundation as an
iCloud item. Missing/unavailable roots produce errors; the server never creates a
local substitute. IDs must be nonempty and unique. Roots cannot overlap or be
symlinks. Choose a dedicated subfolder rather than granting the entire drive.
`icloud_mutation_mode: "allowed"` permits uploads and management; Trash additionally
requires `icloud_trash_enabled: true`. There is no permanent-delete tool.

The host needs access to the selected iCloud folders through macOS privacy settings.
This does not require Mail Automation or Reminders permission. Use the same signed
host identity when troubleshooting privacy access. The Files service never prompts
for an Apple ID or changes sync settings.

## Tool contract

All transports advertise the same 16 tools: stdio, native loopback Streamable HTTP,
and the authenticated remote gateway. The gateway forwards the backend catalog and
calls; it has no separate Files policy. The standard success/error envelope applies.

| Tool | Arguments and result |
| --- | --- |
| `icloud_list_roots` | No arguments. Returns configured IDs/display names and root `item_id`s; no absolute host paths. |
| `icloud_list_items` | Folder `item_id`; optional `limit` (1–200, default 50), `cursor`. Returns `items` and optional `next_cursor`. |
| `icloud_search_items` | Folder `item_id`, nonempty filename `query`; same pagination. Recursive, case-insensitive filename matching; never reads/downloads contents. |
| `icloud_get_item` | `item_id`. Returns metadata and current `revision`. |
| `icloud_download_item` | File `item_id`. Requests macOS local availability; may return `status: download_pending`, `retryable: true`. |
| `icloud_read_file` | File `item_id`, `revision`; optional byte `offset` (default 0), `length` (1–262144, default 262144), `encoding` (`base64`, default; or `utf8`). Returns data, next offset, EOF and revision, or pending-download status. |
| `icloud_begin_upload` | Folder `parent_id`, single-component `name`, expected byte `size`, hexadecimal `sha256`, `idempotency_key`. Replacement also requires `item_id`, `revision` naming exactly that destination. Returns upload ID/status. |
| `icloud_upload_chunk` | `upload_id`, byte `offset`, base64 `data`, `idempotency_key`. Sequential chunks, at most 262144 decoded bytes; identical already-received bytes can be retried. |
| `icloud_get_upload_status` | `upload_id`. Returns status, received and expected bytes. |
| `icloud_commit_upload` | `upload_id`, `idempotency_key`. Verifies complete size/SHA-256 and destination revision/collision/conflict before atomic local publication. Returns item metadata. |
| `icloud_abort_upload` | `upload_id`, `idempotency_key`. Releases receiving uploads and staged data; committed/committing uploads cannot be aborted. |
| `icloud_create_folder` | Folder `parent_id`, `name`, `idempotency_key`. Never overwrites. |
| `icloud_copy_item` | Source `item_id`, `revision`, destination `parent_id`, `name`, `idempotency_key`. Includes descendants; contents must already be local. |
| `icloud_move_item` | Same as copy. Includes descendants. |
| `icloud_rename_item` | `item_id`, `revision`, `name`, `idempotency_key`. Same parent. |
| `icloud_trash_item` | `item_id`, `revision`, `idempotency_key`. Uses macOS Trash and both policy gates. |

Treat references and cursors as opaque. Root references cannot be managed as items.
Names cannot be empty, `.` or `..`, include separators/NUL, or exceed 255 UTF-8 bytes.
References are authenticated and bound to the configured roots; changing a root
configuration invalidates old references. Symlinks and symlinks inside traversed
folder trees are rejected. Packages are opaque metadata/management items; clients
cannot list their internals, read them as ordinary files or upload replacements.

Metadata includes root ID, relative location, kind, size and a revision derived from
filesystem identity, nanosecond modification/change times and descendant metadata.
Pagination cursors are bound to the directory-tree revision and search query; obtain
a fresh page if a cursor becomes stale. Enumeration scans metadata (including tree
revision checks); page limits bound response size, not the total scan cost.

Existing-item mutations require the current revision and reject unresolved cloud
conflicts. An old read revision is also rejected. Revisions are optimistic concurrency
checks; they do not lock the file against uncoordinated local programs. Foundation
coordination protects cooperative access; this is not a sandbox against malicious
programs running as the same macOS user. UTF-8 reads must end on character boundaries;
use base64 for arbitrary byte ranges. Revision/content metadata and filenames are
untrusted data, never instructions or authorization.

Cloud download/upload/conflict fields are reported when macOS provides them.
`cloud_sync_confirmed` always remains false: successful publication means the local
operation completed, not that another device has received it. No automatic conflict
resolution, content search, OCR/extraction, sharing links or package editing is included.

## Staging, retries and recovery

Private state lives under `~/Library/Application Support/apple-platform-mcp/files`
(directory mode 0700; state/parts mode 0600). Upload state, reference key and mutation
receipts survive restarts. Do not delete this directory during active transfers.
A cross-process lock serializes state access across transports; `staging_busy_retry`
means another Files request currently owns the store. Retry later with the same key.

Every mutation needs a nonempty key of at most 200 UTF-8 bytes. Reuse the same key
only for exactly the same tool and arguments. A changed request produces
`idempotency_key_reused`. Successful receipts are retained; identical retries return
the original result even if the file later changes. Use discovery for fresh metadata.

The quota reserves the **expected size** of receiving/committing uploads. The default
is 1 GiB, configurable above. Chunks are never buffered as a whole large file. Publishing
uses a temporary sibling on the destination volume and can temporarily require
additional disk space equal to the file size. Cross-volume copies/moves remain subject
to available disk space and Foundation behavior. Ordinary folder operations are not
quota-limited; the quota concerns upload staging only.

Receiving uploads expire after 24 hours, checked on the next Files call. Status and
receipts remain available; staged bytes are removed. Startup truncates unrecorded
append tails to the last persisted offset. A checksum failure publishes nothing;
abort and start a corrected upload. A stale replacement must be restarted using a
fresh revision; it never silently overwrites a changed file.

A durable intent is recorded before each mutation. If the host exits after a side
effect but before its receipt is persisted, the same key returns
`operation_indeterminate_inspect_before_retry`. Inspect the destination and upload
status before taking further action; never blindly repeat under a new key. A
`committing` upload is retained and reserves quota until an operator reconciles its
local destination/state. This deliberately fails closed for ambiguous crash windows.
A hidden `.apple-platform-upload-*` sibling may remain after an abrupt process exit;
inspect it and the destination before removing it. There is no automatic deletion of
user files or recovery inference from filenames/checksums alone.

Server diagnostics expose configured-root count, write/Trash gates and chunk limit,
without root paths, filenames or contents. Restrict private-state backups to the host
account: opaque references authenticate access but are not encryption of local state.

## Verification

`swift test` exercises isolated filesystem adapters, byte-for-byte multi-chunk
transfers, restart/duplicate retries, replacement, traversal/symlinks, stale revisions,
collisions, quota, expiry, conflicts, pending download and Foundation coordination.
`cd Remote && bun run typecheck && bun test` verifies the gateway regression suite.

An opt-in signed-host check is provided:

```sh
cd Remote
bun run scripts/icloud-smoke.ts /absolute/path/to/signed/apple-platform-mcp
```

It creates a new `ApplePlatformMCP-Smoke-<UUID>` folder in iCloud Drive and a temporary
configuration, then exercises text/binary transfers and management through stdio,
native HTTP and the authenticated loopback gateway. It requests eviction only of its
own text fixture, records whether macOS actually evicted/downloaded it, and leaves
fixtures for inspection. Its JSON report records local results separately from
cross-device sync (which requires independent observation). It never edits the
installed host configuration or deploys the tested executable. See
[iCloud-Files-Evidence.md](iCloud-Files-Evidence.md) for observed results and open gates.

## Current Mac mini deployment

The [deployment record](iCloud-Mac-mini-Deployment.md) identifies the exact
combined source checkpoint, backups and active HighByteTech-only configuration.
Metadata discovery uses immediately-available metadata coordination so directory
reads do not implicitly wait for cloud contents. macOS file-access consent may
still be needed for the signed host; complete that consent before live acceptance.
