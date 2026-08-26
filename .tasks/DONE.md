# Done

## TASK-011: Verify the isolated Reminders live-smoke path
**Priority:** P0 | **Tags:** reminders, tcc, stdio, verification
**Completed:** 2026-08-26

Verified R-001 through R-015 through the app-bundle executable and the real
MCP stdio path without changing the normal user configuration. The temporary
write configuration was supplied only by an explicit absolute `serve --config`
override.

### Verification

- App-bundle TCC: `doctor --request-reminders` obtained Reminders Full Access;
  the final `doctor` report confirms it is allowed. The independent Mail
  Automation check remains denied.
- An isolated live smoke created a fresh list and reminder, then exercised
  create/idempotent retry, read, restart read, update, complete, exact delete,
  and empty-list delete. Cleanup of both fresh objects succeeded.
- SwiftPM: 127 tests passed; native targeted Reminders/stdio tests: 52 tests
  in 13 suites passed with Xcode test parallelization disabled.
- Stdio discovery passed for both the SwiftPM binary and app bundle (21 tools);
  Remote typecheck, 13 tests, and build passed. Bundle signature and plist
  validation, Python script compilation, and `git diff --check` passed.
- Default-parallel Xcode execution can hang while multiple in-memory MCP
  contract suites tear down; the same selected tests pass serially. The
  pre-existing Mail send-contract hang was not changed.

---

## TASK-010: Implement isolated Reminder list lifecycle mutations
**Priority:** P0 | **Tags:** reminders, eventkit, mcp, safety
**Completed:** 2026-08-26

Implemented `reminder_create_list`, `reminder_update_list`, and
`reminder_delete_list`. New lists select their EventKit source only through an
exact opaque source-list reference. Rename and delete resolve their target
exactly; delete additionally requires both policy gates and refuses non-empty
lists before EventKit removal.

### Verification

- RED failure confirmed before the list domain/service/adapter/API existed.
- SwiftPM: 123 tests passed, including list lifecycle service and MCP-contract tests.
- SwiftPM build and `git diff --check` passed.

---

## TASK-009: Implement safe Reminder lifecycle mutations
**Priority:** P0 | **Tags:** reminders, eventkit, mcp, safety
**Completed:** 2026-08-26

Implemented `reminder_create_reminder`, `reminder_update_reminder`,
`reminder_complete_reminder`, and `reminder_delete_reminder`. Every operation
is independently policy-gated, requires a process-local idempotency key, and
uses opaque references with exact EventKit resolution. Patch semantics preserve
omitted fields and use explicit `null` only to clear `notes`.

### Verification

- RED failure confirmed before the lifecycle domain/service/adapter/API existed.
- SwiftPM: 119 tests passed, including lifecycle service and MCP-contract tests.
- SwiftPM build and `git diff --check` passed.
- `swift-format` is not installed on this host; no formatting rewrite was made.

---

## TASK-008: Add Reminders write policy and idempotency foundation
**Priority:** P0 | **Tags:** reminders, policy, idempotency, tdd
**Completed:** 2026-08-26

Implemented the independent `reminder_mutation_mode` policy with a default of
`denied`, fail-closed confirmation mode, and a separate list-delete gate.
Implemented bounded process-local idempotency with stable payload
fingerprints, TTL, capacity eviction, conflicts, and concurrent retry
coalescing. No mutation tool was exposed in this task.

### Verification

- RED failures confirmed before Policy and Store existed.
- SwiftPM: 112 tests passed, including all policy and idempotency cases.

---

## TASK-007: Complete the Reminders R-006 exact read slice
**Priority:** P0 | **Tags:** reminders, eventkit, mcp, read-only, tdd
**Completed:** 2026-08-26

Implemented `reminder_get_reminder` with an opaque versioned input reference,
direct EventKit item lookup, and strict calendar/source/item/external anchor
validation. No heuristic lookup or Reminder write capability was added.

### Verification

- RED failure confirmed before implementing `ReminderToolService.getReminder`.
- SwiftPM: 103 tests passed.
- Stdio discovery passed with `reminder_get_reminder` in the 14-tool catalog.
- Info.plist validation and `git diff --check` passed.

---

## TASK-006: Implement the Reminders R-001 through R-005 read-only slice
**Priority:** P0 | **Tags:** reminders, eventkit, mcp, tdd
**Completed:** 2026-08-26

Implemented the first EventKit-backed Reminders vertical slice without
changing Mail.app behavior. R-006 (`reminder_get_reminder`) remains explicitly
unimplemented.

### Verification

- SwiftPM build and test suite: 100 tests passed.
- Native Xcode targeted Reminders suites: 15 tests passed.
- Native Xcode suite: 98 tests passed with the existing hanging
  `MCPContractTests/sendsThroughMCP()` excluded; the unfiltered run stopped at
  that test after 44 passed tests.
- Stdio E2E discovery and Remote gateway typecheck, tests, and build passed.

### Release gates

- A live Reminders permission grant and dedicated macOS 13/14 fixtures remain
  outstanding.
- Save/update/restart/full-sync reference lifecycle testing is deferred because
  this scope excludes Reminders writes and no permissioned fixture was used.
