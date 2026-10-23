# iCloud Files implementation evidence

Initial development verification: 2026-10-23. Implementation is complete; full
live acceptance remains open under TASK-013. At this stage deployment and host
configuration were unchanged. The subsequent [Mac mini deployment](iCloud-Mac-mini-Deployment.md)
is now complete with HighByteTech as the sole root.

## Automated verification

- `swift test`: **147 tests in 35 suites passed**, including existing Mail and
  Reminders regression suites and 14 Files fixture tests.
- `swift build`: passed.
- `Remote`: `bun run typecheck` and **13 tests passed**.
- External Python stdio handshake: protocol 2025-06-18, all **37 tools** discovered
  (21 existing tools plus 16 iCloud tools); no private content emitted.
- Python script compilation and `git diff --check`: passed.

Fixtures verify empty files, UTF-8/base64 reads, 700,123-byte binary transfers,
three sequential chunks, exact duplicates, new-key duplicate retries, process-state
reloads after each chunk, commit receipts after restart, interrupted append tails,
24-hour expiry, SHA-256 failures, staging quota, default-denied writes and Trash,
root protection, authenticated traversal rejection, symlink substitution, overlapping
roots (including case aliases), paginated recursive filename search, stale cursors,
stale descendant revisions, collisions, replacement, copy/move/rename/Trash,
cloud conflicts, pending downloads and opaque packages. Ambiguous persisted
mutation intents are verified to fail closed instead of blindly replaying.

## Signed real-host smoke

A separate copy of the SwiftPM executable was Developer ID signed with Hardened
Runtime for this test. `codesign --verify --strict` passed. This is a signed CLI
host test, not a notarized app release or deployment.

Using only a new disposable iCloud folder and a temporary absolute `--config`,
the real signed backend completed the following through **stdio, native HTTP and
the authenticated loopback remote gateway**:

- Discovery of all 16 Files tools.
- Chunked upload, duplicate chunk retry, commit and duplicate commit retry.
- Byte-for-byte download of **700,123 binary bytes** with SHA-256
  `556eb5973271e1e321c7a7a739f1314c5a7aa90d9ea762e498d0dca9a1d2969f`.
- UTF-8 text roundtrip, folder creation, recursive filename search, copy,
  rename, move and real macOS Trash.

This smoke exposed an existing native HTTP write path that closed its socket
before a large response finished flushing. The listener now closes only after
the final write completes. A real-loopback regression verifies the complete
1 MiB response body, and the signed HTTP/Gateway roundtrips pass.

## Remaining live acceptance

Initial immediate eviction requests returned `NSFileProviderErrorDomain -2008`.
After macOS reported `is_uploaded: true`, later `brctl evict` requests completed,
but repeated metadata observations still reported
`NSURLUbiquitousItemDownloadingStatusCurrent`. The download request succeeded and
text remained readable. **A genuinely evicted file was not observed**, so real
pending-download/re-download acceptance remains open despite passing simulations.

**Synchronization on another device was not observed.** Local publication, local
roundtrip checks and macOS upload status do not prove cross-device synchronization.
The service continues to report `cloud_sync_confirmed: false`.

TASK-013 tracks those two external acceptance gates. Do not treat the local smoke's
`localSuccess: true` as `acceptanceComplete: true`. Test fixtures remain for
independent inspection; no existing user files were selected or altered.

## Final run artifact

The final smoke report and signed executable checksum are recorded below after the
last verification run. The opt-in reproduction script is
`Remote/scripts/icloud-smoke.ts`; it never edits the installed configuration.

- Retained fixture: `ApplePlatformMCP-Smoke-7f7f4595-db49-4b4a-a429-4c7b89ddf964`.
- Local report: `<private-local-report>`.
- Signed executable SHA-256: `8692b3d4d75bfde80b06843b7ccc5a6b1e255a860039aef007f0166faa7661d0`.
- Final report: `localSuccess: true`, `acceptanceComplete: false`.

## Mac mini configuration preparation — 2026-10-23 (before deployment)

- Verified host: `mac-mini.local`, macOS account `$HOME`.
- Existing iCloud root: `$HOME/Library/Mobile Documents/com~apple~CloudDocs/HighByteTech`.
- Host `~/.config/apple-platform-mcp/config.json` now has exactly one Files root:
  ID `highbytetech`, name `HighByteTech`, path above. Writes remain denied and
  Trash disabled. Existing Mail/Reminders/Notes/Calendar configuration values
  were preserved and checked after the atomic write.
- Original backup: `config.json.backup-20261023T101746364554Z` in the same private
  configuration directory; original/backup SHA-256:
  `c601d2bf93525ff31e61cb723033f6f7d0fa2dc9f83361f55e80c205689166b5`.
- Installed app stdio discovery: server version `0.1.0`, 35 tools, **zero**
  `icloud_` tools. The root configuration is prepared but Files functionality
  is not yet deployed/active on the Mac mini.
- No app replacement, service restart, account changes or new iCloud folders.
  TASK-014 is complete for configuration preparation; deployment remains separate.

The later [verified Mac mini deployment](iCloud-Mac-mini-Deployment.md) supersedes
the prepared-but-inactive state above. TASK-015 records installation and acceptance.
