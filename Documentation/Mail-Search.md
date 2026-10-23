# Native Mail search

## Execution path

`MailSearchPredicate` builds a native first pass from `from`, `subject`, `after`,
`before`, `unread_only` and `flagged_only`. The Objective-C bridge applies it
directly to the remote `SBElementArray` and resolves only matching message
references. Swift never bridges/enumerates the unfiltered array to apply these
predicates. Counts of unfiltered collections are cached per search source.

The existing query matcher remains the final check, before offset pagination
and newest-first merging. Date bounds are strict at that stage. Native bounds
are widened to whole seconds to avoid loss at the Apple Event date boundary.
Sender/subject arguments are predicate constants, including quotes, percent
signs and Unicode; they never become executable predicate syntax.

Recipient key paths are unsupported by ScriptingBridge. `to` stays a residual
filter; combine it with a native filter or an explicit mailbox where possible.
Unfiltered/recipient-only searches retain indexed collection traversal, which
is still potentially expensive. Body-backed `query` remains disabled.

Canonical Inbox references returned by search can be reused with
`scope=mailbox` even when that Inbox lives outside the account mailbox tree.
Account matching and the complete canonical mailbox path remain required.

The bridge catches Objective-C exceptions, checks Apple Event errors and
restores the previous delegate/timeout. It returns sanitized errors without
predicate values; unsupported predicates never silently fall back to a full
scan. A 20-second timeout bounds each native mailbox query, not the entire
request or Mail.app's internal work. Returned candidates can still be large.
No private Mail database, extra search index, body cache or new permission is
introduced. Native predicates do not prove use of Mail's UI/Spotlight index.

Apple references:

- [Using Scripting Bridge: element arrays](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptingBridgeConcepts/UsingScriptingBridge/UsingScriptingBridge.html)
- [ScriptingBridge predicate limitations and error handling](https://developer.apple.com/library/archive/releasenotes/ScriptingAutomation/RN-ScriptingBridge/index.html)

## Verification and activation

1. Preserve the existing worktree. Run Swift tests with the installed Xcode
   toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), Python
   rollout guards, Remote tests/typecheck and `git diff --check`.
2. Generate the project with `xcodegen generate`. Reuse
   `Scripts/build-signed-notes-candidate.py` (historical filename) for a new
   signed universal Release candidate. Verify source digest, unchanged bundle/
   team, Hardened Runtime, entitlements and strict signature. Do not overwrite
   an installed app while it is running.
3. Launch the exact candidate app through Launch Services on an unused loopback
   port with an isolated config: all mutations/sending denied and a separate
   Calendar journal. Wait for `/health/live` before the smoke runner. Reuse
   existing consent; any missing macOS consent remains operator-owned.
4. Run `python3 Scripts/verify-mail-search-live-smoke.py --url
   http://127.0.0.1:<port>/mcp`. It requires an existing nonempty Inbox and a
   nonempty reference subject, checks known sender/subject/case/status/date
   results, ordering, available continuation pages and a random no-match term.
   `--tax-queries` adds the five explicitly requested tax searches. It reads
   summaries only, writes no messages and persists only counts/timings.
5. Verify read-only Mail accounts, Notes accounts, Reminders lists and Calendar
   calendars on the isolated candidate; confirm mutation modes remain denied.
6. Back up the installed app and config privately, recording their hashes and
   a read-only digest of the production Calendar journal. Stop the gateway and
   exact installed backend, stage/activate the verified app and restart the
   existing LaunchAgent. Preserve the production config and newest journal.
7. Verify installed binary hash/process, local liveness/readiness, unauthenticated
   gateway/public rejection and the actual connected client's search. Capture
   sanitized timings, tool results and regressions separately from local tests.
8. Stop the isolated host. If activation fails, stop the failed backend, restore
   the verified previous app and restart the gateway. Never replace/delete the
   newest Calendar journal during rollback. Recheck health and read access.

No notarization, public release, mailbox mutation or tax-completion judgment is
part of this change. Search is a live snapshot; concurrent new mail or message
moves can change offset pages, as before.
