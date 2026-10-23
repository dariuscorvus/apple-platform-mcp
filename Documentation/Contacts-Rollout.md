# Contacts V1 signed rollout

1. Preserve all current changes and TASK-014/TASK-015. TASK-016 stays In Progress
   until isolated, deployed and actual connected-client reads pass.
2. Run Xcode-SDK Swift tests, Python rollout guards and Remote tests/typecheck.
   Generate the existing Xcode project. Use `build-signed-notes-candidate.py`
   (historical filename) with a new private output directory. It verifies source
   digest stability, unchanged bundle identity, Developer ID team, universal
   Release archive, Hardened Runtime, exact entitlements and Contacts description.
3. Verify signed stdio discovery. Through Launch Services run the candidate app
   with `doctor --request-contacts`, stdout/stderr in private files. The operator
   confirms macOS consent personally. Never automate the permission decision.
4. Start candidate HTTP on an unused loopback port with an isolated configuration:
   all mutation modes denied; separate Calendar journal path. Do not reuse or
   clear the production Calendar journal. Run `verify-contacts-live-smoke.py`
   using a private explicit query JSON (1–4 operator-selected names). It searches
   at limit five, reads only a single unambiguous result from a complete scan,
   and emits sanitized counts. No contact values or references are persisted.
5. Regression-read Mail accounts, Notes accounts, Reminders lists and Calendar
   calendars on this actual host; do not create fixtures. If any gate fails,
   stop before installation, retain the candidate and report the exact gate.
6. Back up installed app/config privately; snapshot Calendar SQLite through its
   backup API for evidence. Preserve the NEWEST active journal, including WAL.
   After isolated acceptance stage and strictly verify the candidate, stop the
   managed gateway/backend, replace only the app, and restart the same LaunchAgent.
   Production configuration/policies and Calendar journal remain unchanged.
7. Verify backend path/hash, health/readiness, unauthenticated rejection,
   authenticated local gateway and authenticated public route independently.
   Repeat read smoke/regressions. A separate official SDK client proves only
   independent-client behavior. Refresh the actual connected ChatGPT/Codex
   catalog and verify all three Contacts calls separately. Never claim that
   server_info or another client proves actual Contacts tool selection.
8. Record sanitized results, hashes, host permission, limitations and work log.
   No notarization, public release, contact writes, sends or invites.

## Rollback

The retained previous app is `~/Applications/apple-platform-mcp-pre-contacts.app`;
the verified private backup is recorded in Contacts-Rollout-Evidence.md.
Stop managed gateway/backend, restore verified app backup and restart existing
LaunchAgent. Recheck permissions and read regressions. No config changes are
needed for Contacts. Keep the NEWEST production Calendar journal, including
successful reservations: backups are forensic evidence, NEVER replacements.
For journal damage, disable writes and reconcile; do not delete/reset it.
Retain smoke evidence and candidate until client acceptance is complete.
