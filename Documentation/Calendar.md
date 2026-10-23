# Calendar V1

Calendar uses a dedicated, serialized EventKit repository. Both stdio and
streamable HTTP expose the same six tools; the gateway remains a transport and
authentication layer. Existing events and calendars are never edited or deleted.

| Tool | Arguments |
| --- | --- |
| `calendar_list_calendars` | none |
| `calendar_search_events` | `time`, optional `calendar_ids`, `query`, `limit` |
| `calendar_get_event` | `event_id` |
| `calendar_check_conflicts` | `time` |
| `calendar_create_event` | `calendar_id`, `title`, `time`, `idempotency_key`; optional `location`, `notes` |
| `calendar_get_creation_outcome` | `idempotency_key` |

Unknown fields and incorrect types are rejected, including fields inside `time`.
Calendar text is untrusted data and never authorizes an action. Invitations,
attendee operations, alarms, and creation of recurring events are outside V1.
Existing series are returned as individual occurrences.

## Time and references

`time` is an object containing `start`, `end`, `time_zone`, and optional
`all_day` (default false). Timed values use ISO-8601 with seconds, up to three
fractional digits, and an explicit offset. The offset/local time must agree with
the explicit IANA zone, for example `2026-11-01T10:00:00+01:00` and
`Europe/Berlin`. Invalid dates, zones, nonexistent local times, and inconsistent
offsets are refused. Ambiguous autumn times are distinguished by their offsets.

All-day values use `YYYY-MM-DD`, with an exclusive end date and explicit zone.
They represent calendar days rather than multiples of 86,400 seconds. Floating
or all-day events read from EventKit use the event store's current default zone,
reported as `time_zone_source=event_store_default`; other events use their own
zone. The search window is limited to 366 calendar days. `max_results` defaults
to 50 and is capped at 1,000, including explicitly requested limits. There is no
pagination. `truncated=true` reports output truncation or an incomplete backend
scan; the backend scan has a separate 10,000-occurrence safety bound.

References are versioned, canonical, sorted-key JSON encoded as `cal_v1_…`.
Calendar references bind source and calendar IDs. Event references additionally
bind the provider identity, original occurrence date (where available), and exact
start/end instants. Resolving a series occurrence performs a bounded EventKit
query and exact anchor matching; stale, ambiguous or incomplete resolution fails.
There is no title fallback or first-occurrence fallback. Refresh a search after
an external event edit invalidates its reference.

## Permission and write policy

Calendar requires Full Access. `doctor` reports the status without prompting.
Only explicit `doctor --request-calendar` requests access. MCP calls never show
permission dialogs; write-only permission is insufficient. The app includes
legacy and Full Access usage descriptions and uses the macOS 14+ API with a
macOS 13 compatibility branch. macOS 13 runtime support must be verified on an
actual macOS 13 host before claiming compatibility. See Apple's
[TN3152](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels).

Configuration is independent from Mail, Notes and Reminders:

```json
{
  "calendar_mutation_mode": "denied",
  "calendar_allowed_write_calendar_ids": []
}
```

Only `allowed` plus membership in the explicit allowlist permits creation.
`confirmation_required` remains blocked because no confirmation flow exists.
Missing/empty allowlists permit no destination. The service never chooses a
default calendar. References, Full Access and current provider writability are
checked before writing. Calendar listings distinguish `can_write` (provider)
from `policy_allows_write` (provider and local policy).

## Conflicts

Checks examine all readable calendars and report their references and a
`status` of `complete`, `incomplete`, or (in creation results) `failed`.
Intervals are half-open: an event ending at the proposed start is not a conflict.
Cancelled and explicitly free events are excluded. Other overlaps include
all-day and recurring occurrences. Output truncation is separate from scan
completeness; `count` counts the overlaps found by the scan.

Creation performs its own check, independent of a previous search response.
Overlaps do not block creation. `overlapping_events_detected` and
`conflict_check_incomplete`/`conflict_check_failed` warn as appropriate. A failed
or incomplete check must never be described as conflict-free. This is a snapshot,
not a reservation; events may change immediately afterwards.

## Durable creation outcomes

The default journal is
`~/.local/state/apple-platform-mcp/calendar-idempotency.sqlite3` (directory 0700,
file 0600). An absolute `calendar_journal_path` override is available for isolated
non-production tests. Keep the production path stable through restarts and
rollbacks. Linked, corrupt, inaccessible or unexpected journals fail closed.

The journal reserves a hashed key and normalized request fingerprint using a
SQLite immediate transaction before EventKit may save. SQLite locking protects
multiple processes. A successful retry returns the recorded reference and
original conflict summary without creating another event. The same key with a
different normalized payload is rejected. Stored data contains hashes, state,
timestamps and necessary result references; titles, locations and notes are not
stored. Entries are never automatically deleted.

A crash or failure after reservation leaves `outcome_unknown`, including the gap
between EventKit save and journal commit. Neither retries nor title matching
resolve it automatically. `calendar_get_creation_outcome` reads the saved state
without attempting a write (`not_found`, `in_flight`, `outcome_unknown`, or
`succeeded`). Inspect the dedicated calendar manually before deciding on any new
key. Journal errors block new writes. Existing Notes/Reminders journals are not
migrated.
