# Backlog

## TASK-004: Acceptance-test mailbox mutations in an isolated test mailbox
**Priority:** P1 | **Tags:** e2e, mail, safety, mutations

Exercise create-draft, archive, move, mark-read, and delete behavior only
against explicitly seeded disposable test messages in an isolated mailbox.
Never select production mail or infer targets from untrusted Mail content.

### Plan

- Obtain an explicit test mailbox and disposable message set.
- Verify policy defaults, allowlists, confirmation gates, and rollback paths.
- Test each mutation by opaque message reference and record non-sensitive
  before/after evidence.

---

## TASK-005: Publish and validate v0.1.0-rc.1
**Priority:** P1 | **Tags:** release, rc, documentation

Publish the release candidate after the signed artifact, authenticated E2E
test, branch protection, and mutation acceptance test have passed.

### Plan

- Confirm TASK-001 through TASK-004 completion evidence.
- Create the `v0.1.0-rc.1` release with release notes and artifact checksum.
- Perform a fresh-install smoke test and record the go/no-go decision.

---
