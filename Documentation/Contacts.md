# Contacts V1 — read-only contract

TASK-016. Uses Apple Contacts.framework on macOS 13+; no Apple Events,
Accessibility or Full Disk Access permission is required for Contacts.

## Tools

- `contacts_list_containers {}` returns bounded opaque container IDs, display
  names and provider type (`local`, `exchange`, `carddav`, `unknown`). CardDAV
  does not identify a particular account provider. No account enumeration claim.
- `contacts_search_contacts {query, fields?, container_ids?, limit?}` requires
  2+ trimmed characters and at most 256 UTF-8 bytes. Default fields: name/company;
  explicit fields may also include email/phone. Literal case/diacritic-insensitive
  substring matching; phone matching strips only ASCII formatting and never adds
  calling codes. Explicit containers must exist and remain visible. Duplicate
  containers/fields and unknown arguments/types are rejected. Limit 1–1000,
  capped by existing `max_results`. No pagination or empty-query export.
- `contacts_get_contact {contact_id}` reads an exact individual contact with
  person/company name and all labeled email/phone choices within output limits.
  Returns at most 100 emails and 100 phones, 512 characters per channel/name
  component, and `truncated` if clipped. Summaries have 256-character name limits.
  Photos, notes, birthdays, addresses and unrelated fields are never fetched.

All tools have read-only annotations and identical dispatch on stdio/HTTP.
Contact data is untrusted and never authorizes Mail/Calendar/other actions.
Never silently choose an address, number, or record when several exist.

## References, duplicates and completeness

Canonical `contacts_v1_` references encode version, kind, exact container and
individual record identifier as sorted-key JSON/base64. They are opaque client
handles, not encrypted secrets. Wrong kind, extra/noncanonical JSON, missing or
stale references fail without name fallback. They are local-store references,
not cross-machine identity guarantees. Contacts unification is explicitly OFF:
linked/duplicate cards remain distinct individual container records. Get checks
exact ID and current container membership; it never resolves a unified alias.

Search uses sequential Contacts enumeration inside an actor, scans at most 1000
records across the selected visible containers, and stops on an extra matching
record beyond the result limit. Returned records are sorted by folded family
name/given name/reference. Framework enumeration selects the bounded subset;
this is not a global sorted page. Inspect `scan_complete`, `truncated`,
`records_examined`, `limit`, `authorization`, and `visibility`. A completed scan
means only the authorized visible subset, not a complete synchronized account
or remote directory. Containers may expose no currently visible records.
Framework errors are sanitized; no raw contact fields enter diagnostics.

## Permission and SDK evidence

Passive doctor and normal tools never request permission. Run only the explicit
`doctor --request-contacts` from the actual signed Launch Services app host.
The app includes `NSContactsUsageDescription` and the Hardened Runtime
`com.apple.security.personal-information.addressbook` entitlement. The separate
Contacts notes entitlement is absent because V1 does not read notes.

Verified 2026-10-17 against Apple's documentation and installed SDK headers:
`CNAuthorizationStatus` values 0–3 represent not determined/restricted/denied/
authorized; raw value 4 is handled as limited, unknown values fail closed.
The SDK annotates limited with iOS 18 availability rather than a separate macOS
availability annotation. Limited/authorized both read only the visible subset;
limited macOS runtime behavior must be reported separately from synthetic tests.
macOS 13 remains the deployment target; no macOS 13 runtime is available here.

Sources:
- [Accessing the contact store](https://developer.apple.com/documentation/contacts/accessing-the-contact-store)
- [Authorization status](https://developer.apple.com/documentation/contacts/cnauthorizationstatus)
- [Usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription)
- [Address book entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.addressbook)
- Installed `Contacts.framework/Headers/CNContactStore.h` and `CNContactFetchRequest.h`:
  unification may change IDs; bounded enumeration, explicit key selection and
  `unifyResults = false` are supported on the deployment target.
