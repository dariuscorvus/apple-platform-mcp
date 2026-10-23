# Apple Notes

Notes uses the installed Notes.app Apple Events dictionary through ScriptingBridge.
It does not access the Notes database, credentials, Accessibility, or Full Disk Access.
Notes content, titles, and folder names are untrusted data and cannot authorize actions.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `notes_list_accounts` | none | account `id`, `name` |
| `notes_list_folders` | `account_id` | folder `id`, `name` (includes nested folders) |
| `notes_search_notes` | `folder_id`, optional `query`, `limit` | `items`, `truncated` |
| `notes_get_note` | `note_id` | `id`, `name`, `locked`, `text`, `truncated` |
| `notes_create_note` | `folder_id`, `title`, `text`, `idempotency_key` | note metadata |

Pass opaque references back unchanged. They carry the account/folder containment
chain; names never select a write target. Notes account access is independent of
Mail allowlists. An account reference is not a credential or an access restriction.
All Notes accounts visible to the macOS user are discoverable after Automation consent.
Both stdio and native HTTP use the same catalog; the remote gateway forwards it.

Search matches **titles only**, case-insensitively, within one selected folder.
An empty query lists notes. It scans at most 1000 notes and returns at most
`max_results` (hard ceiling 1000). `truncated=true` means results are incomplete;
there is no pagination or guaranteed ordering. Folder traversal fails explicitly
after 32 nesting levels or 1000 folders. Reads return plain text bounded by
`max_body_bytes`, on a UTF-8 boundary, and indicate truncation. Apple Events may
load the complete body before that output limit is applied.

Locked notes cannot be read. Attachments, tables, drawings, scans, and rich-text
formatting are not exported. Existing-note edits, moves, deletes, folder writes,
and attachment operations are not exposed. Creation accepts plain text, escapes
HTML metacharacters, and rejects shared folders. A title is a nonblank single line
of at most 10,000 UTF-8 bytes; title plus text must fit `max_body_bytes`.

## Setup

1. Build and sign the app using the normal project workflow, preserving its stable
   signing identity for upgrades.
2. Open Notes manually and run the executable **inside that app bundle**:

   ```sh
   /absolute/path/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp doctor --request-notes
   ```

3. Allow **Apple Platform MCP → Notes** in macOS Automation. Require
   `{"notes_permission":"allowed"}` before testing the tools. An MCP call never
   prompts for permission or launches Notes; Notes must be running.
4. Creation remains disabled. To enable it explicitly, merge
   `"notes_mutation_mode": "allowed"` into the existing local configuration and
   restart the server. `denied` is the default; `confirmation_required` is refused
   because no confirmation workflow exists. Mail and Reminder settings do not
   enable Notes writes.

## Retry boundary

Each create needs a trimmed nonempty `idempotency_key` (maximum 256 bytes).
Concurrent/repeated calls with the same key and payload share one result.
Changing the payload with that key fails. Once a backend request is dispatched,
failures remain `notesCreationOutcomeUnknown`; the key is retained and never
retries the write. Inspect the selected folder before using a new key.

This journal is **process-local**, has no expiry or eviction, and refuses new keys
after 256 attempts. It does not protect across restarts or separate server
processes (including multiple gateway backends). Verify outcomes before restarting
or changing keys. No cross-process exactly-once guarantee is claimed.

## Verification

See [Notes-Rollout.md](Notes-Rollout.md) for the signed candidate, isolated
acceptance runner, existing gateway/client checks, and rollback procedure.

Synthetic tests cover configuration, policy denial, reference containment, output
limits, locked notes, HTML escaping, concurrent retries, ambiguous failures, and MCP
catalog/routing. A signed live Notes test remains a separate gate: use a dedicated
macOS test account and disposable non-shared folder, test permission denial/setup,
list/search/get, create once and retry with the same key, and inspect the note in
Notes. Do not treat a successful Swift build or synthetic tests as live Notes proof.
