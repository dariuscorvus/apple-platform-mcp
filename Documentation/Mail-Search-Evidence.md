# Native Mail search verification — 2026-10-17

## Result

Supported sender, subject, date and read/flagged-status constraints now run in
Mail.app through native ScriptingBridge predicates. Recipient matching and
strict final comparisons remain local. Canonical Inbox references also work
when reused with explicit mailbox scope. No extra index or private Mail
database access was introduced.

The signed universal Release candidate was activated after isolated acceptance.
The actual connected MCP client's `from=accountable`, `scope=inbox`, `limit=1`
request succeeded with one result and no continuation: **636 ms server time,
4715 ms total connector time**. The same single-result search previously
returned a request timeout/504 in this conversation. These are individual
observations, not a latency guarantee or a completeness claim for all mail.

## Verification

- SwiftPM using the Xcode toolchain: **177 tests / 41 suites passed**, including
  five new native-filter tests and the extended canonical Inbox integration.
  Checks cover literal/Unicode values, compound constraints, widened native
  date bounds, unsupported recipient paths, sanitized Objective-C exceptions,
  timeout restoration and existing traversal/cursor contracts.
- Python rollout guards: **20 passed**. Remote: **18 passed / 47 assertions**;
  TypeScript typecheck passed. Signed external stdio discovery exposed all
  **34 tools**. Project generation, universal archive, strict signature,
  Hardened Runtime, exact entitlements and source/binary digest checks passed.
- Isolated signed loopback host: known subject, two case variants, sender,
  unread/flagged filters, strict dates, no-match handling and ordering passed.
  Separate native recent-window verification compared a three-result page
  with first/second single-result continuation pages; references matched.
- Operator-requested isolated Inbox searches, metadata only:

  | Filter | Results | Duration |
  | --- | ---: | ---: |
  | Sender contains Accountable | 1 | 5920 ms |
  | Subject contains Steuer | 1 | 5954 ms |
  | Subject contains Umsatzsteuer | 1 | 5943 ms |
  | Subject contains Finanzamt | 0 | 4287 ms |
  | Subject contains ELSTER | 1 | 5989 ms |

  These rows can refer to the same message. They cover Inbox metadata only,
  not archived mail, message bodies, attachments or tax-process completion.
- Mail accounts, Notes accounts, Reminders lists, Calendar calendars and
  Contacts containers read successfully on both the isolated and installed
  hosts. Isolated mutation/sending policies were all denied. No mutation tool
  was called.
- Installed backend `/health/live` and `/health/ready`, gateway `/healthz` and
  `/readyz` returned **200**. Unauthenticated POST to the configured gateway
  MCP path returned **401**. Actual authenticated connected-client search
  succeeded; public unauthenticated access was not separately re-probed.

## Artifact and preservation

- Installed executable SHA-256:
  `e9dc74d63d8e721b09478a111ba2124e0f4c69afd67f68ee745d20af2af71dcf`.
- Bundle ID `com.dariuscorvus.apple-platform-mcp` and Developer ID team
  `4WF4549NW5` remained unchanged. No new permissions or entitlements.
- Production config bytes and the read-only logical digest of the Calendar
  journal matched their pre-activation baselines. The newest journal was
  never replaced, reset or deleted.
- Previous installed app/config and signed candidates are retained privately in
  `~/.local/state/apple-platform-mcp/mail-search-rollout/20261017-native-search/`.
  Sanitized isolated, continuation, activation, actual-client and final-check
  JSON records are retained there; mail values/references were not persisted.
- The provisional first candidate exposed the pre-existing canonical Inbox
  resolution issue and was not activated. The corrected second candidate
  passed the acceptance checks. The isolated host was stopped after rollout.
- Existing worktree changes and TASK-014/TASK-015/TASK-016 acceptance gates were
  preserved. No notarization, public release, commit or push was performed.

## Limits and repeatable checks

Use [the search runbook](Mail-Search.md) and
`Scripts/verify-mail-search-live-smoke.py`. Native scripting predicates do not
prove use of Mail's UI/Spotlight index. Broad candidate sets and unfiltered or
recipient-only traversals can remain expensive. The native timeout applies per
mailbox query; it is not a whole-request deadline. A macOS 13 runtime was not
available for live testing. No separate search index is currently required to
make the verified queries work.
