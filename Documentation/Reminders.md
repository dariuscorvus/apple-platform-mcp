# Reminders lifecycle

Status: R-001 through R-015 are implemented. The complete read/write
lifecycle passed an isolated, permissioned MCP stdio smoke test on the current
macOS 26.6.2 host: list/create/read/update/complete/delete for one freshly
created Reminder and create/rename/delete for one freshly created list. The
test cleaned up both objects. macOS 13 runtime/TCC verification remains a
release compatibility gate; it does not block the current-host capability.

## Architecture

The Reminders path is separate from the Mail.app path:

```text
MCP
  -> ReminderToolService
  -> ReminderRepository
  -> EventKitReminderRepository
  -> EventKit
  -> Reminders
```

Only `EventKitReminderRepository` imports EventKit. The repository and service
exchange `ReminderList`, `ReminderItem`, `ReminderDue`,
`ReminderRecurrence`, and opaque reference values; no EventKit object or Apple
framework identifier is part of the MCP schema.

## Permission and compatibility

All Reminders operations require Full Access. MCP tool calls never request it
implicitly; setup is explicit:

```sh
apple-platform-mcp doctor --request-reminders
```

On macOS 14 and later the adapter calls EventKit's
`requestFullAccessToReminders` API. On macOS 13 it uses the legacy
`requestAccess(to: .reminder)` API and normalizes its authorized state to
`full_access`. Both `NSRemindersFullAccessUsageDescription` and
`NSRemindersUsageDescription` are present in the app bundle.

The package and app deployment target remain macOS 13. The macOS 14+ API is
runtime-guarded, so raising the whole app target is not needed and would
unnecessarily change the working Mail.app V1. A dedicated macOS 13 machine
must still pass the TCC and lifecycle smoke before a production claim of macOS
13 reliability.

See Apple's [EventKit access documentation](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
and the [Reminders Full Access usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription).

## MCP surface

Read tools return opaque `rr1_` references, which clients must pass back
unchanged:

- `reminder_list_lists`
- `reminder_list_reminders` with `list_id`, optional `completed`,
  `due_after`, `due_before`, and a server-clamped `limit`
- `reminder_get_reminder` with `reminder_id`

The lifecycle tools are policy-controlled and require a non-empty
`idempotency_key`:

- `reminder_create_reminder`: `list_id`, `title`, optional `notes`, `priority`,
  and an explicit `due` value
- `reminder_update_reminder`: `reminder_id` plus one or more of `list_id`,
  `title`, `notes`, or `priority`; omit a field to preserve it and send
  `notes: null` to clear it
- `reminder_complete_reminder`: `reminder_id`
- `reminder_delete_reminder`: `reminder_id`; permanently destructive
- `reminder_create_list`: explicit `source_list_id` and `name`
- `reminder_update_list`: `list_id` and `name`
- `reminder_delete_list`: `list_id`; permanently destructive and allowed only
  for an empty list

`ReminderDue` is normalized on reads and can be supplied on create. All-day
values use `date` plus `all_day: true`; timed values require `date`, `time`,
and an explicit IANA `time_zone`. The create response is read back from
EventKit, so it returns the native due value that was persisted. Recurrence
write inputs remain intentionally out of scope for this slice.

## Write policy and idempotency

Reminder writes are independent from Mail send and mailbox-mutation policy.
Missing configuration is safe: `reminder_mutation_mode=denied` and
`reminder_list_delete_enabled=false`.

```json
{
  "reminder_mutation_mode": "allowed",
  "reminder_list_delete_enabled": true
}
```

`confirmation_required` is deliberately fail-closed because this transport has
no separate confirmation protocol. List deletion needs both
`reminder_mutation_mode=allowed` and the explicit second gate above. The
adapter also counts reminders and refuses a non-empty list before asking
EventKit to remove it.

Every mutation is keyed by its operation and normalized request payload.
Retries with the same key and payload return the original result; a reused key
for a different operation or payload returns `idempotencyConflict`. The store
is bounded and process-local (one-hour TTL, 256 completed entries). It
coalesces concurrent same-process retries, but it intentionally provides no
restart or cross-process idempotency guarantee.

For an isolated test or an operationally separate launch, `serve` accepts one
explicit absolute override without changing the normal user configuration:

```sh
apple-platform-mcp serve --transport stdio --config /absolute/path/config.json
```

## Exact reference resolution and stability

The wire format is a versioned `rr1_` token. Its adapter-private anchor
contains the calendar/source identifiers and, for an item,
`calendarItemIdentifier` plus `calendarItemExternalIdentifier` when present.
The token is opaque at the MCP boundary and is not a secrecy mechanism.

No operation resolves by title, due date, list scan, or external-identifier
search fallback. Item reads and writes use EventKit's direct
`calendarItem(withIdentifier:)` lookup, then validate calendar, optional
source, item identifier, and optional external identifier exactly. Lists are
looked up by exact calendar/source anchors. A stale reference fails closed with
a normalized not-found error.

The isolated live smoke verified that the same opaque list and reminder
references remained usable after EventKit save, list rename, reminder update,
completion, and a second stdio server process. EventKit can represent a
cleared note as an empty string; the adapter normalizes that storage detail to
an absent MCP `notes` value.

Apple does not guarantee `calendarIdentifier` or `calendarItemIdentifier`
across a full sync, and external identifiers are not a unique cross-device
lookup key. Therefore no cross-device/full-sync stability claim is made.
Clients must re-list after a stale-reference error; the server will never fall
back to heuristic resolution. See Apple's [calendarIdentifier documentation](https://developer.apple.com/documentation/eventkit/ekcalendar/calendaridentifier),
[calendarItemIdentifier documentation](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier),
and [calendarItemExternalIdentifier documentation](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier).

## Three-stage real smoke test

Use an app-bundle executable, not just the SwiftPM binary, so macOS associates
the permission with the bundle's Info.plist.

1. Build the app and grant/check Full Access.

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodegen generate --spec project.yml
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild -project ApplePlatformMCP.xcodeproj -scheme ApplePlatformMCP \
     -configuration Debug -derivedDataPath /tmp/apple-platform-mcp-build build

   APP=/tmp/apple-platform-mcp-build/Build/Products/Debug/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp
   "$APP" doctor --request-reminders
   ```

   Allow **Apple Platform MCP** Reminders Full Access if macOS prompts. A
   non-zero doctor exit can still reflect the independent Mail Automation
   check; require `reminder_permission: pass` in its JSON report.

2. Create a temporary opt-in configuration and list source choices without
   mutation. Select one returned opaque writable `id`; the runner never picks a
   source itself.

   ```sh
   SMOKE_DIR=$(mktemp -d /tmp/apple-platform-mcp-reminders-smoke.XXXXXX)
   cat > "$SMOKE_DIR/config.json" <<'JSON'
   {
     "reminder_mutation_mode": "allowed",
     "reminder_list_delete_enabled": true
   }
   JSON

   python3 Scripts/verify-reminders-live-smoke.py \
     --binary "$APP" --config "$SMOKE_DIR/config.json" \
     --list-writable-sources
   ```

3. Run the explicitly authorized isolated lifecycle. It creates only
   `Apple Platform MCP Smoke Test <run-id>` objects, retries the create calls
   in-process for idempotency, restarts the stdio server between reads and
   update, and deletes the exact created reminder and empty list at the end.

   ```sh
   python3 Scripts/verify-reminders-live-smoke.py \
     --binary "$APP" --config "$SMOKE_DIR/config.json" \
     --confirm-live --source-list-id 'rr1_opaque-source-reference'
   ```

The runner emits only status, stages, and cleanup state; it does not print
Reminder contents or Apple identifiers. On failure it attempts cleanup only
with the exact fresh references it created.

## Explicitly out of scope

This implementation does not expose Calendar, Contacts, additional Mail
features, heuristic resolution, Reminder alarms or recurrence writes, or a
durable cross-restart idempotency store.
