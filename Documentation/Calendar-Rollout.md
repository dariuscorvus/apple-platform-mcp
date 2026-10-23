# Calendar signed rollout runbook

Task: TASK-015. Retain the existing bundle identifier and Developer ID identity.
Notarization and public release are outside this local rollout.

1. Preserve the working tree. Run the full Swift suite and Calendar transport,
   journal/process, crash and time tests. Generate the Xcode project when source
   membership changes. Build using `Scripts/build-signed-notes-candidate.py
   --build --output <new-private-directory> --derived-data <existing-cache>`.
   Despite its historical name, this helper verifies the complete app, source
   digest, Release metadata, Hardened Runtime, identity/team and entitlements. Calendar requires
   `com.apple.security.personal-information.calendars` even without App Sandbox;
   otherwise TCC denies prompting before any user decision.
2. Back up the installed app and configuration privately. Record signature,
   source and binary hashes. If a Calendar journal exists, snapshot it with
   SQLite's backup API. Never reset or replace it with an older snapshot.
3. Run the candidate's `doctor --request-calendar` through Launch Services,
   using `open -W -n -g --stdout <private-file> --stderr <private-file>
   <candidate.app> --args doctor --request-calendar`. The operator must approve
   Full Access. Direct command-line consent may belong to a different host.
   Restart the background process after consent to renew EventKit state.
4. Discover calendars with `Scripts/verify-calendar-live-smoke.py --binary
   <candidate-binary> --config <isolated-config> --discover`. Capture output
   privately; choose the account with the operator if multiple suitable sources
   exist. In Calendar create a dedicated **Apple Platform MCP Live Test**
   calendar. Keep existing calendars unchanged. Allow only its returned opaque
   reference in the isolated configuration.
5. Run the smoke script with `--calendar-reference-file <private-file>
   --manifest <new-private-manifest> --mode create --confirm-live`. It reserves
   its operator manifest before dispatch and retains three synthetic fixtures
   (timed, overlap, all-day). Keep the same server journal path through rollout.
   Run `--mode replay` with the same manifest in a fresh server process to verify
   durable outcomes before any retry. Use a separate denied configuration and
   new manifest with `--mode deny`. Inspect the synthetic events directly in
   Calendar. Never automatically rerun an interrupted create using a new key.
6. Only after isolated acceptance, stage and verify the signed candidate,
   stop the managed gateway/backend, replace the installed app and atomically
   merge only `calendar_mutation_mode=allowed` plus the one-calendar allowlist
   into the existing configuration. Keep all other settings. Restart the managed
   service and check readiness and the executable hash of its actual backend.
7. Verify authenticated loopback gateway, unauthenticated rejection and the
   public route separately. Use private authentication files, never print tokens.
   Run synthetic create/read/retry and post-restart replay through the gateway.
   Verify Mail, Notes and Reminders reads remain reachable. Refresh/reconnect
   the actual client and separately verify six tools plus a Calendar event read.
8. Retain fixtures and private manifests. Record sanitized evidence and any
   unverified gate. TASK-015 remains In Progress until actual client acceptance.

## Rollback

Stop the managed service, restore the retained previous app and its configuration,
verify signature and restart. Recheck Mail/Notes/Reminders permissions, since
host/signature changes can affect macOS consent. Preserve the newest Calendar
journal and all smoke manifests even when rolling back to a build without
Calendar support. A stale journal backup is forensic evidence, not a rollback
replacement: restoring it could remove successful reservations and create
later duplicates. For an unreadable journal, block Calendar writes and reconcile
unknown outcomes manually; do not delete it to recover service.
