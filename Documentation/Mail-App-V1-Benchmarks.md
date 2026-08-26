# Mail.app V1 workflow benchmarks

## Purpose

This benchmark answers the V1 question: are the concrete agent workflows usable
through Mail.app/ScriptingBridge? It is not a generic ScriptingBridge speed
claim and it is not an authorization to add IMAP.

The checked-in Swift test uses a deterministic synthetic fixture and emits one
aggregate `MAIL_WORKFLOW_BENCHMARK` JSON line. The local diagnostic script
`Scripts/run-mail-workflow-benchmark.py` uses the current Mail.app installation
for a non-persistent diagnostic only. It keeps account/message references and
message contents in memory and prints timing/count aggregates only.

Every local operation has a 15-second hard request deadline. Broad archive
search has no hard V1 target; it is measured and reported separately.

## Target budgets

| Workflow | V1 target |
| --- | ---: |
| list accounts | < 1 s |
| list mailboxes | < 1–2 s |
| newest 10 Inbox | < 2 s |
| unread 10 Inbox | < 3 s |
| get metadata only | < 1–2 s |
| get message body | < 3 s |
| sender search in Inbox | < 5 s |
| subject search in Inbox | < 5 s |
| broad archive search | measure only |

Targets are goals, not guarantees. The broad search result must not be used to
claim that all archive searches are fast.

## Synthetic verification

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SyntheticWorkflowBenchmarkTests
```

The fixture covers accounts, mailboxes, newest/unread Inbox search, sender and
subject filters, metadata-only detail, body detail, and explicit broad archive
scope. Separate tests verify newest-first ordering, early stopping, actual
inspected-work bounds, query/scope cursor binding, and that summary searches do
not read message bodies.

## Local Mail.app diagnostic — 2026-08-25

Command:

```sh
python3 Scripts/run-mail-workflow-benchmark.py --request-timeout 15
```

The following is the aggregate of three independent local runs. No account
names, addresses, subjects, opaque references, message bodies, credentials, or
filesystem paths were written to a benchmark artifact.

| Workflow | Median | Max | Result count | Target |
| --- | ---: | ---: | ---: | --- |
| list accounts | 111 ms | 143 ms | 1 | pass |
| list mailboxes | 565 ms | 566 ms | 6 | pass |
| newest 10 Inbox | 1,801 ms | 1,824 ms | 10 | pass |
| unread 10 Inbox | 2,371 ms | 2,385 ms | 10 | pass |
| sender search in Inbox | 2,022 ms | 2,028 ms | 10 | pass |
| subject search in Inbox | 2,059 ms | 2,076 ms | 10 | pass |
| get metadata only | 762 ms | 763 ms | 1 | pass |
| get message body | 774 ms | 800 ms | 1 | pass |
| broad archive search | 1,728 ms | 1,729 ms | 10 | measured only |

The local run used one enabled Mail.app account and six visible account
mailboxes. Mail.app exposed an aggregate Inbox container plus an
account-specific Inbox child; the repository now prefers the account-specific
canonical candidate and can resolve message references from that candidate.

## Interpretation

The measured core V1 workflows are within their target budgets on this Mac.
Broad archive search is also measurable in this sample, but it remains an
explicit broader scope with no hard target and no snapshot guarantee. These
measurements do not justify a second protocol backend.
