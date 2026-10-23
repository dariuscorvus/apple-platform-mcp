# iCloud Files deployment on Mac mini

Deployed and verified on 2026-10-23. The signed Release app is running at
`$HOME/Applications/apple-platform-mcp.app` on `mac-mini.local`.
The existing authenticated gateway and LaunchAgent remain in use.

## Released source and identity

The Mac mini checkout contained newer, uncommitted Mail search, Notes, Calendar
and Contacts work that was absent from the local development checkout. An
isolated integration preserved that entire source snapshot and added Files;
the Mac mini's working checkout was not overwritten.

- Exact release checkpoint: `d4bed24d3f5e00a4ad438c9a2c1811f262b5cd39`.
- Original base commit: `e94e85928167b7f123e22c317f5e2aa09f978b51`.
- Build-input SHA-256 (Sources, Config, Package files and project.yml):
  `76515548f8e5f5ffe92c9f9adbf9d599ba84c5c125bae9ca1a6da140590c17a6`.
- Installed executable SHA-256:
  `6c06fabaef7fed52441c544a875a32f11147172b6c794e727b1eeb80ac2a9093`.
- Same bundle ID `com.dariuscorvus.apple-platform-mcp` and Developer ID team
  `4WF4549NW5` as the previous installation. Universal arm64/x86_64 Release,
  Hardened Runtime, exact existing entitlements and strict deep signature checks
  passed. This private host update was not a notarized/public release.

The original deployment checkpoint is retained privately as a Git bundle and
source archive. This integration publishes the combined source as a sanitized
squash on main; future builds should use main. The installed binary retains the
original checkpoint identity above until the next deployment.

## Effective file access

Exactly one configured root:

```json
{
  "id": "highbytetech",
  "name": "HighByteTech",
  "path": "$HOME/Library/Mobile Documents/com~apple~CloudDocs/HighByteTech"
}
```

`icloud_mutation_mode` remains `denied`; `icloud_trash_enabled` remains `false`.
The existing folder and its descendants are accessible. No additional iCloud
roots, replacement local folders or file-writing permissions were added.

The prepared production config remained byte-for-byte unchanged throughout the
app deployment (verified against its private backup).
Existing Mail/Notes/Reminders/Calendar policy values and the gateway plist were
preserved. No journal or user-data store was restored or replaced.

## Verification

- Combined Swift suite: **195 tests in 43 suites passed**.
- Files regression subset in the development checkout: **15 tests passed**.
- Gateway: TypeScript check and **18 tests / 47 assertions passed**.
- Python rollout guards: **20 tests passed**.
- Universal signed archive and strict deep signature verification passed locally
  and on the Mac mini.
- Isolated Launch Services candidate on port 8769 and installed host on port 8765
  both passed the same live read checks.
- **51 tools** advertised: all 35 previously installed tools plus 16 `icloud_`
  tools. No previous domain was removed.
- Live root discovery returned only HighByteTech; root metadata and bounded
  listing succeeded. Tampered references were rejected, and folder creation and
  Trash probes were denied by policy.
- Mail account, Notes account, Reminders list, Calendar calendar and Contacts
  container reads succeeded. Only counts/status were retained, not user content.
- Installed backend and gateway readiness returned 200. Unauthenticated gateway
  access remained 401.
- The existing authenticated MCP connection's actual `mail_server_info` call
  returned the release checkpoint above, one iCloud root, write mode denied,
  Trash false and 262144-byte chunks.

During initial iCloud onboarding a coordinated folder read timed out. The
operator granted the requested macOS file-access permission, after which the
isolated read checks passed. Independently, discovery now explicitly uses
Foundation's immediately-available-metadata-only coordination option, avoiding
implicit waits for cloud contents. Pending reads check availability before
requesting content coordination; a dedicated regression verifies the distinction.

The first installation attempt was automatically rolled back because the extra
native probe tried to initialize a server already initialized by its gateway.
The probe now recognizes only that specific already-initialized response and uses
unique request IDs. The final installation and live checks passed. App backups
from both attempts remain available.

Public client selection of the new Files tool bindings was not exercised in this
conversation; authenticated remote diagnostics were. The broader real-eviction
and independent-device synchronization acceptance gates remain in TASK-013.
Local success and upload status do not establish cross-device synchronization.

## Backups and reproducibility

Private rollout directory on the **Mac mini**:

```text
$HOME/.local/state/apple-platform-mcp/icloud-rollout/20261023-icloud-2fa6bb2c/
```

Retained artifacts:

- `manifest.json`, `deployment.json`, `isolated-smoke.json`, `installed-smoke.json`.
- `candidate-app-v3.tar.gz`: accepted signed app.
- `release-source-final.bundle`: exact Git checkpoint and its history.
- `combined-source-final.tar.gz`: checkout/archive of that checkpoint.
- `macmini-source.tar.gz`: original host working source before integration.
- `backup-retry-1/installed-previous.app` and `installed-copy.app`: previous
  installed app; executable SHA-256
  `e9dc74d63d8e721b09478a111ba2124e0f4c69afd67f68ee745d20af2af71dcf`.
- `backup-retry-1/config.json`, `gateway.plist`, `manifest.json`: private,
  verified pre-swap backups. The initial attempt's `backup/` is also retained.
- Deployment/verification scripts and failure evidence from earlier attempts.

For app rollback, unload the existing gateway LaunchAgent, gracefully stop only
its installed backend, retain the current app as a failed-candidate backup,
restore the verified previous app at the same installation path, then bootstrap
that same LaunchAgent and verify readiness/diagnostics. Do not overwrite live
Calendar journals or other data/idempotency stores with historical snapshots.
