# Contacts V1 rollout evidence

Observed 2026-10-17 on macOS 26.6.2. TASK-016 remains **In Progress** for
actual connected-client Contacts tool selection. Implementation, isolated
Launch Services reads, installed gateway and public HTTPS reads passed.

## Implementation and automated verification

- Three read-only tools; actor-isolated CNContactStore, strict arguments,
  canonical individual-container references, bounded scan/output and explicit
  authorized-subset completeness. No contacts created/modified/deleted, no
  messages/invitations sent and no address books exported.
- Xcode-SDK Swift: **172 tests in 40 suites passed**. Existing Mail/Notes/
  Reminders/Calendar suites plus Contacts permissions, strict validation,
  references, Unicode/phone matching, duplicates, channel choices, output caps,
  privacy and both protocol transports.
- Python rollout guards: **20 passed**. Gateway: **18 tests, 47 assertions passed**;
  TypeScript typecheck and `git diff --check` passed. Gateway port tests passed
  outside the sandbox after sandboxed port binding was rejected.
- Command Line Tools lack the Testing module; verification used the installed
  Xcode SDK. macOS 13 deployment branch builds, but no macOS 13 runtime was
  available. Limited Contacts authorization is covered synthetically; the live
  host reported authorized, so limited-mode macOS behavior remains unverified.

## Signed installed identity

- Bundle ID `com.dariuscorvus.apple-platform-mcp`, Developer ID team `4WF4549NW5`
  and signing identity remained unchanged. Universal Release archive, Hardened
  Runtime, explicit executable metadata, strict deep signature verification,
  exact Apple Events/Calendar/Contacts entitlements and usage descriptions passed.
- Installed executable SHA-256:
  `dce3aef79c0b5a93a959e8c9c1aacaa2ad73b869090c25f1dd9f500055d61265`.
- Source SHA-256:
  `cbcea4ba63604fe498ea9076b8b0297b630f279d223559228a17ec4830d31855`.
- Base commit `e94e85928167b7f123e22c317f5e2aa09f978b51` with retained pre-existing
  uncommitted work; the source digest identifies the actual candidate inputs.
- Signed external stdio handshake/discovery passed: all three Contacts tools,
  34 tools total. No notarization, public release, commit or push performed.

## Actual host and live reads

- `doctor --request-contacts` ran in the signed candidate through Launch Services.
  Operator personally confirmed the visible macOS dialog. Result: `authorized`.
- Initial four operator-selected names and their surnames had zero matches.
  Enumeration examined one visible record in one local container. The operator
  confirmed that only that local card exists in Contacts on this Mac. No remote
  account completeness was inferred, and no contacts were imported or created.
- Operator-confirmed existing local contact was then used: exactly one match,
  complete visible-subset scan, exact-reference `contacts_get_contact` succeeded,
  no truncation. The card has zero emails and zero phones; real populated channel
  formatting is therefore not live-verified, only synthetically tested.
- Isolated actual-host Mail accounts, Notes accounts, Reminders lists and Calendar
  calendars read successfully. All isolated mutation policies were confirmed denied.
- Installation occurred only after isolated acceptance. Private installed-app/
  config backup and staged candidate were verified; existing LaunchAgent restarted.
  Actual installed backend process path and executable hash match the candidate.
- The production configuration is byte-for-byte unchanged. Six Calendar journal
  rows and their contents are unchanged from the pre-rollout baseline. No journal
  reset, rollback replacement or Calendar fixture creation occurred.
- Authenticated loopback gateway and public HTTPS (system curl) independently
  discovered and called all three Contacts tools: container list, bounded search,
  exact get. Mail/Notes/Reminders/Calendar read regressions also passed on each route.
  Counts only were retained; no contact values or contact references were persisted.
- Readiness returned 200. Unauthenticated loopback/public route returned 401.
  Isolated testhost stopped; temporary query/auth/session-request files removed.

## Actual connected-client boundary

The existing connected client's real `mail_server_info` call succeeds against
this installed build and reports `contacts_adapter_configured=true`,
`contacts_permission=authorized`, `contacts_read_only=true`. Existing Calendar
Full Access and policy configuration are retained.

This conversation's callable client metadata still offers no `contacts_*`
bindings. Thus it cannot execute a real client-selected Contacts list/search/get
call here. Public curl and an independent SDK client are not proof of that gate.
No independent SDK client was substituted for the required actual-client proof.
A refreshed client catalog exposing the three bindings plus successful actual
calls is the remaining acceptance gate. TASK-016 stays In Progress; TASK-014 and
TASK-015 and their separate acceptance gates were not modified or closed.

## Evidence and rollback

Private retained directory:
`~/.local/state/apple-platform-mcp/contacts-rollout/20261017-contacts-v1/`.
It holds strictly verified `candidate.app`, app/config backup, candidate and
backup manifests, isolated smoke/regressions, deployment, routes and final checks.
The SQLite snapshot is forensic evidence only. Operator query values, contact
names, email/phone values and contact references are absent from repository
and retained acceptance evidence.

The previous app is also retained at
`~/Applications/apple-platform-mcp-pre-contacts.app`. Follow
[Contacts-Rollout.md](Contacts-Rollout.md): stop managed gateway/backend, restore
the verified previous app and restart/recheck reads. Configuration need not
change. **Always keep the newest active Calendar journal**; never replace it
with the older forensic snapshot. An unreadable journal blocks writes until
reconciled; deleting/resetting it is not a recovery step.
