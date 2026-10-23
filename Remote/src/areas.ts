/** Stable service connections over one backend. These are catalog boundaries,
 * not separate identities or replacements for the native mutation policies. */
export const APPLE_AREAS = [
  { name: "mail", title: "Apple Mail", path: "/apple/mail", toolPrefix: "mail_" },
  { name: "reminders", title: "Apple Reminders", path: "/apple/reminders", toolPrefix: "reminder_" },
  { name: "notes", title: "Apple Notes", path: "/apple/notes", toolPrefix: "notes_" },
  { name: "calendar", title: "Apple Calendar", path: "/apple/calendar", toolPrefix: "calendar_" },
  { name: "contacts", title: "Apple Contacts", path: "/apple/contacts", toolPrefix: "contacts_" },
  { name: "icloud", title: "Apple iCloud Drive", path: "/apple/icloud", toolPrefix: "icloud_" },
] as const;

export type AppleArea = (typeof APPLE_AREAS)[number];
