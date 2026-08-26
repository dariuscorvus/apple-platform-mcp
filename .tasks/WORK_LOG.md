# Work Log

Completed tasks are recorded here with a short date and verification summary.

## 2026-08-26 — TASK-011

Verified the R-001 through R-015 Reminders lifecycle through a Full-Access app
bundle and real stdio MCP smoke. Fresh named list/reminder objects were
created, read across restart, updated, completed, and exactly deleted; cleanup
passed. SwiftPM passed 127 tests, native targeted Reminders/stdio checks passed
52 tests serially, both stdio discovery paths exposed 21 tools, and Remote
typecheck/tests/build passed. The independent Mail Automation denial and the
default-parallel Xcode transport-teardown hang remain documented test risks;
no Mail code changed.

## 2026-08-26 — TASK-010

Completed R-013 through R-015: explicit-source list create, exact rename, and
double-gated empty-list delete. SwiftPM passed 123 tests; build and whitespace
checks passed.

## 2026-08-26 — TASK-009

Completed R-009 through R-012: policy-gated, process-local-idempotent
Reminder create, patch update, complete, and delete tools with exact opaque
reference resolution. SwiftPM passed 119 tests; build and whitespace checks
passed. `swift-format` was unavailable on the host.

## 2026-08-26 — TASK-008

Completed R-007/R-008: independent default-denied Reminder write policy and
bounded, process-local idempotency foundation. SwiftPM passed 112 tests.

## 2026-08-26 — TASK-007

Completed R-006 with direct, fail-closed opaque-reference reminder reads.
SwiftPM (103 tests), stdio discovery, plist validation, and whitespace checks
passed. No write feature was added in this task.

## 2026-08-26 — TASK-006

Implemented the R-001 through R-005 Reminders read-only slice with EventKit
permission handling, adapter/domain separation, versioned opaque references,
bounded list/reminder tools, and documentation. R-006 and all writes remain
out of scope. SwiftPM (100 tests), native targeted Reminder tests (15), native
tests excluding the known hanging Mail send-contract test (98), stdio E2E, and
Remote typecheck/tests/build passed. Live Reminders TCC, macOS 13/14 fixture,
and reference lifecycle verification remain release gates.
