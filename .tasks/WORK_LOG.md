# Work Log

## 2026-10-23 — TASK-017: Scoped Apple gateway connections

Implemented six `/apple/<area>` connections with discovery and invocation
boundaries, shared authentication and legacy compatibility. Typecheck/build and
23 tests/231 assertions passed. Best practice documented in Service-Connections.
Source verified; no host or Cloudflare configuration deployment performed.

## 2026-10-23 — TASK-016: Full deployed source integration

PR #2 integrates all six domains and 51 tools into main through required checks.
Local Swift 195, native Xcode, gateway 18/typecheck/build and Python 20 passed.
Private checkpoint history and runtime configuration are excluded. Host policies
remain unchanged; extended cloud acceptance stays in TASK-013.

Completed tasks are recorded here with a short date and verification summary.

## 2026-10-23 — TASK-015

Deployed signed universal checkpoint d4bed24 to the Mac mini, preserving all
35 existing tools and adding 16 Files tools restricted to HighByteTech. Writes
and Trash remain denied; existing domain reads, live authenticated diagnostics,
readiness and signature/hash checks passed. Swift 195, gateway 18/typecheck,
Python 20 and development Files 15 tests passed. Verified app/config/plist
backups retained; original dirty source checkouts and production configuration
unchanged. An initial probe failure rolled back safely; the corrected final
installation passed. See Documentation/iCloud-Mac-mini-Deployment.md for exact
source checkpoint, hashes and rollback paths. TASK-013 remains open.

## 2026-10-23 — TASK-014

Configured the Mac mini's existing HighByteTech iCloud folder as the sole Files
root after a checksum-verified backup; writes/Trash denied and all other settings
preserved. Installed stdio discovery has 35 tools and no icloud tools, so active
Files access requires a separate deployment. No app replacement or restart.

## 2026-10-23 — TASK-012

Completed configured iCloud Files implementation and signed local verification:
16 tools, confined roots, independent write/Trash gates, revision/conflict checks,
durable 256 KiB chunks, quota/expiry and fail-closed retry receipts. Swift build,
147 tests, gateway typecheck/13 tests and external 37-tool discovery passed.
Signed real-iCloud text/binary and management roundtrips passed over all three
transports; native HTTP large-response flushing was fixed and regression-tested.
Full acceptance remains open in TASK-013 for genuine eviction/re-download and
independent second-device sync observation. Host configuration/deployment unchanged.

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
