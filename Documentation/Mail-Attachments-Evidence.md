# Mail attachment feasibility evidence

Date: 2026-10-17. TASK-019 remains In Progress. TASK-020–022 remain dependent
Backlog tasks. No attachment tools are registered and no rollout is authorized
by this evidence. Existing working-tree changes were preserved.

## Static evidence

Run `python3 Scripts/inspect-mail-attachment-capabilities.py`. This reads only
the installed Mail.sdef, emits its SHA-256 and explicit declarations, and sends
no Apple Events. A true declaration is NOT a successful Mail operation.

The installed dictionary declares received attachment save, ID, approximate
file size and downloaded state; outgoing message save and integer ID; rich-text
attachment file insertion. Neither the dictionary nor generated bindings
establish a stable relationship between outgoing IDs and saved mailbox message
IDs after Mail/server restart. The existing create-draft bridge returns a Boolean
without explicit save or durable identity; it cannot support exact editing yet.

Attachment metadata now excludes missing/empty/duplicate IDs rather than issuing
an index-based reference. Synthetic identity tests cover duplicate rejection and
reordering. Metadata remains metadata-only; no file export was added.

Apple documentation: [SBObject](https://developer.apple.com/documentation/scriptingbridge/sbobject)
describes lazy object specifiers, not durable identity guarantees.
[SBApplication timeout](https://developer.apple.com/documentation/scriptingbridge/sbapplication/timeout)
defines reply timeout; it does not establish a deadline for an entire multi-event
workflow. Future prototype must bound each event and the overall operation.

## Required isolated runtime evidence

Operator must name a dedicated account/mailbox and a synthetic received fixture.
Do not select personal mail, discover fixtures by subject, or send test messages.
Record only counts, hashes, sanitized failure codes and operation timings:

1. Resolve exact account/mailbox/message/attachment IDs; export one cached fixture
   into private 0700 staging and compare actual byte count and SHA-256.
2. Exercise unavailable attachment and per-event/overall timeout behavior. A
   declared approximate size is not sufficient for actual-byte quota enforcement.
3. Create an isolated unsent draft with synthetic bytes; explicitly save, read back
   recipients/body/attachment hashes and remove only its exact attachment.
4. Persist a private exact reference, restart the isolated host, resolve uniquely,
   then separately test Mail restart only with operator coordination. Never infer
   a draft using subject/recipient matching. If identity fails, mark existing-draft
   operations unsupported; do not advertise them.
5. Retain outcome journal before dispatch. An ambiguous save/send is unknown and
   must not be retried blindly. Live send requires separate explicit instruction.

## Dependent implementation and rollout gates

The proposed 10 files / 20 MiB per file / 25 MiB total remain unvalidated product
defaults. Export/import must be independently denied by default. Private staging
must reject symlinks, enforce actual-byte quotas, expire opaque references, snapshot
selected bytes and bind retries to request/hash/policy. No client-chosen paths.

Finalize schemas only after runtime feasibility. Local staged-file reuse is a
separate capability from ChatGPT download/upload. There is no actual client
file-transfer evidence here. Do not introduce public static routes or bearer links.

Before activation: full regressions; signed isolated host; matching stdio/HTTP
schemas and denied-default tests; authenticated transfer acceptance in the actual
client; private app/config backup; rollback preserving newest durable journals.
Keep tasks open for missing evidence. Production app/config were not changed.

### Verification recorded 2026-10-17

- Installed dictionary inspection passed; SHA-256
  `111b9291c502354106a320f6ba0a7e38ed29f09e443404679fb57778708b0722`.
- Two new synthetic attachment identity tests passed.
- Full Xcode Swift suite: 179 tests / 42 suites passed. This includes the existing
  local read-only Mail integration; it does not prove attachment runtime behavior.
- `git diff --check` passed. No attachment export/import, draft mutation, send,
  signing, deployment or client file transfer performed by this change.
- Operator-selected isolated account/mailbox and synthetic received fixture are
  pending. Restart-safe draft identity, insert/remove, unavailable-file timeout
  and actual client upload/download remain unverified. No tasks moved to Done.

## Authorized self-send probe (2026-10-17)

The operator replaced the isolated-account requirement with synthetic self-send,
then explicitly selected `user@example.com` as both sender and recipient. Production
`send_mode=denied` and all account/mailbox/mutation policies remain unchanged.
The test used a separate local AppleScript feasibility harness, not a deployed
MCP attachment implementation. No authentication/transport parity claim follows.

- A private 0700 work directory contains 0600 synthetic fixtures and a durable
  SQLite operation journal. Writes reserve a key before Apple Events; repeated
  keys do not dispatch again. Journals/fixtures are retained for reconciliation.
- Created and saved one synthetic draft with attachment. Mail returned outgoing
  ID `0`. A fresh process reported attachment counts first 0, then 1 after insertion,
  then 0 again. A metadata-only reconciliation found one synthetic Drafts message
  with one received-style attachment. No subject-based recovery was used to mutate
  or send that saved mailbox draft. The saved fixture remains untouched.
- The existing-draft send probe failed with AppleScript coercion error `-1700`.
  Its journal remains unknown, with no retry. Further preflight failed attachment
  count check `7007`. This does not establish reliable saved-draft sending.
- A distinct direct-create-and-send synthetic fixture was accepted by Mail (`true`)
  within one invocation, after checking the single attachment count and self-only
  sender/recipient. This independent probe has its own reserved journal key and
  different request token; it is not a retry of the unknown saved-draft request.
- Sent attachment fixture SHA-256:
  `59c6c5ed56528d0d7763575ad8dbff7165174468b3be425b7f6ac28ec1234e2e`.
- Exact synthetic subject search in the connected client's Inbox and all-account
  traversal returned zero matches at observation time. A matching outgoing item
  remains visible. Recipient receipt and export hash comparison are NOT verified.
  Do not automatically resend based on absence from search results.

Contract decision: do not expose inspect/add/remove/send-existing-draft until a
restart-safe exact identity and reviewed revision are demonstrated. Mail integer
outgoing ID 0 is not a durable draft reference. Direct-create/send is only an
adapter feasibility lead; it does not justify production support yet. Received
export remains pending receipt of the synthetic fixture. Uncached timeout behavior,
Mail restart, signed-host adapter equivalence and actual client file transfer remain
open. No task has been moved to Done and no application/config deployment occurred.
