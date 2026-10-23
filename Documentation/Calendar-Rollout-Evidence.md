# Calendar V1 local rollout evidence

Observed 2026-10-17 on macOS 26.6.2. TASK-015 remains **In Progress** until an
actual client's Calendar-tool read is verified. Implementation, isolated live
acceptance and installed gateway/public acceptance have passed.

## Build and identity

- Bundle ID: `com.dariuscorvus.apple-platform-mcp` (unchanged).
- Developer ID Application team: `4WF4549NW5` (unchanged).
- Identity SHA-1: `F9B4EDD174E886C3B8BEB43A7E5EBFB78B23424C`.
- Installed executable SHA-256:
  `67ee5d408174ccf09662faff7b6b0ee973296f07eb89555d54bc344a8782d801`.
- Source input SHA-256:
  `e1df88dcd039450700acde5918af59a96d3b5fc996be1fda8c84d748785754dd`.
- Release universal archive; Hardened Runtime; strict deep signature verification;
  explicit executable metadata; Apple Events and Calendar personal-information
  entitlements verified. No App Sandbox or additional runtime exceptions.
- Build base commit `e94e85928167b7f123e22c317f5e2aa09f978b51`, with preserved
  uncommitted Notes/Mail changes and Calendar implementation. The source digest,
  rather than the base commit alone, identifies this candidate's inputs.
- Not notarized; no public release created.

## Automated verification

- Swift: **164 tests in 39 suites passed**, including Calendar domain, recurrence
  resolution, policy/permission, time/DST, SQLite reservation/concurrency/restart,
  process locking, crash boundaries and both transport contracts.
- Python rollout guards: **16 passed**, including existing Notes safeguards and
  new Calendar manifest/replay/denial/target/entitlement checks.
- Remote gateway: **18 tests passed, 47 assertions**; TypeScript typecheck passed.
- Signed candidate stdio handshake/catalog passed with all six Calendar tools.
- `git diff --check` passed. macOS 13 compatibility branch compiles, but no macOS
  13 runtime was available; that compatibility is not confirmed.

## Isolated and installed live results

- Actual Launch Services candidate host reports Calendar `full_access`.
- Discovery found one suitable writable source (iCloud); a separate unshared
  **Apple Platform MCP Live Test** calendar was created in Calendar's UI.
- Only that exact opaque calendar reference is in the write allowlist.
- Isolated denied-mode creation rejected before reservation; no fixture created.
- Three isolated synthetic fixtures verified: a timed event, overlapping timed
  event and all-day event with exclusive end. Titles, location, multiline notes,
  umlauts and HTML special characters read back correctly. Their times, all-day
  dates and note text were also inspected directly in Calendar.
- Same-key repetitions returned identical results; after stopping and restarting
  the isolated Launch Services host, outcomes and creation retries returned the
  same three IDs. No duplicate fixtures were created.
- Installed app replaced only after isolated acceptance. App/config backup and
  staged strict verification completed. Only `calendar_mutation_mode=allowed`
  and the test-calendar allowlist were added to the existing config.
- Actual installed backend process path and binary hash match the verified
  candidate. Backend and gateway were stopped/restarted under their existing
  LaunchAgent; readiness returned 200.
- Authenticated gateway created/read/searched three additional synthetic fixtures,
  verified conflict warnings and identical retries. A further backend/gateway
  restart preserved all outcomes and returned the same event references.
- Six total synthetic events retained; six journal rows succeeded. No pending
  Calendar reservation remained at this observation. Existing events/calendars
  were not edited or deleted.
- Mail account read, Notes account/read of retained synthetic note and Reminders
  list read succeeded after restart. Unauthenticated gateway request returned 401.
- Public HTTPS route: authenticated system curl discovered all six tools and
  read a retained synthetic Calendar event. Python urllib was rejected by
  Cloudflare WAF error 1010 (browser signature); no protection was weakened.
- Actual connected-client Notes read (retained synthetic note) and Reminders
  list read also succeeded after the rollout.
- The actual connected client's `mail_server_info` returned the Calendar-enabled
  build, `full_access` and configured allowlist. This conversation's callable
  metadata still has no `calendar_*` tools, so this is **not** a successful actual
  client Calendar-read test. Operator refreshed the connection; a fresh-chat
  list/search/get acceptance check is pending.

## Live issues resolved before acceptance

1. Candidate 01 lacked `com.apple.security.personal-information.calendars`.
   TCC logs showed that Hardened Runtime prevented prompting. Candidate 01 was
   never installed and performed no Calendar writes. Candidate 02 adds and
   verifies the entitlement; the actual app host now has Full Access.
2. The pre-existing state directory was 0755. The journal correctly refused a
   new write before reserving a key or invoking EventKit. The directory was
   tightened to 0700. Missing journal/outcome and empty synthetic-fixture search
   were explicitly reconciled, then the exact original keys/requests were used.
   The failed runner manifest is retained and marked reconciled. The server
   journal is now 0600. No ambiguous post-reservation write was retried.
3. The existing native stateless HTTP server rejects a second initialization of
   its one SDK instance. The Calendar operator harness attaches to an already
   initialized instance only for that exact error and verifies tool readiness.
   Gateway/production transport behavior was not changed by this rollout.

## Evidence and rollback

Private evidence directory:
`~/.local/state/apple-platform-mcp/calendar-rollout/20261017-calendar/`.
It contains the candidate manifest, app/config backup, private auth files,
operator manifests, route/read verification and SQLite snapshots. Never copy
private auth/config contents into issue reports or this repository.

The retained previous app is also at
`~/Applications/apple-platform-mcp-pre-calendar.app`. Follow
[Calendar-Rollout.md](Calendar-Rollout.md) to stop the managed service, restore
that app and the backed-up config, verify identity and recheck permissions.
**Always retain the newest Calendar journal**; snapshots are forensic evidence,
not rollback replacements. Reverting the journal could remove reservations and
allow duplicates. Test fixtures remain for operator review.

## Independent client acceptance — 2026-10-17

At the operator's request, the remaining list/search/get flow was executed
autonomously using a separate client built on the official MCP TypeScript SDK.
It connected to the authenticated **public HTTPS** route, initialized normally,
discovered all six Calendar tools, listed calendars, selected the exact retained
test-calendar reference, searched 2026-10-31 through 2026-11-03, and read a
returned synthetic event. All three calls succeeded; the search returned exactly
three fixtures from the selected run and the notes matched the expected Unicode
and multiline text. No new Calendar events were created by this verification.

Private machine-readable evidence: `independent-client-read.json` in the rollout
directory. This verifies a real external MCP client, separately from curl and
loopback tests. The connected ChatGPT client's `mail_server_info` also succeeds
and reports Calendar Full Access. Its callable tool catalog in this conversation
still contains no Calendar bindings, so **ChatGPT-specific Calendar tool
selection remains unverified**. TASK-015 stays In Progress for that exact gate;
no further operator test was assumed or claimed.
