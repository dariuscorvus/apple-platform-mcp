# Mail.app-only V1 — Status Report

Stand: 2026-08-26

## Ergebnis

Die Mail.app-only-V1 ist auf einen kontrollierten Abschluss gebracht. Mail.app
bleibt der einzige Backend-, Account-, Credential- und Versand-Owner. Der
Server verwendet ScriptingBridge/Apple Events; er verwaltet weder IMAP-/SMTP-
Credentials noch eine parallele Mail-Datenbank.

Nicht Bestandteil der V1 sind private Mail-Datenbankzugriffe, Accessibility,
Computer Use, Screen Scraping, permanentes Löschen und das Leeren des Trash.
Die aktuelle kontrollierte Mutationserweiterung publiziert Draft-, Move-,
Archive-, Trash- und Status-Tools, bleibt aber ohne lokale Konfiguration durch
`mutation_mode=denied` gesperrt. `mail_send_message` bleibt separat durch
`send_mode=denied` gesperrt.

Die zwei zwischenzeitlich fehlenden `origin/main`-Commits wurden integriert:

- der notarized-macOS-Release-Workflow;
- die Mail-Use-Case-Roadmap und Phase-0-Evidenz.

## Implementiert

- Default-Scope `inbox` über Mail.app-kandidierte canonical Inbox;
- explizite Scopes `inbox`, `mailbox` und `all`;
- newest-first-Anwendungstraversal mit Page-/Lookahead-Begrenzung;
- opaque, query- und scope-gebundene Cursor;
- Account-/Mailbox-Allowlist und serverseitige Result-, Body- und Send-Limits;
- Metadaten-Reads ohne `message.source`, Body-Parsing oder Attachment-Inhalte;
- getrennte Send-Modi `denied`, `allowed` und `confirmation_required`;
- getrennte Mutation-Modi `denied`, `allowed` und fail-closed
  `confirmation_required`;
- Account-, From-Identity-, Empfänger-, Subject- und Body-Validierung vor dem
  Delegieren an Mail.app;
- policy-gesteuerte `mail_create_draft`, `mail_move_message`,
  `mail_archive_message`, reversible `mail_trash_message` und
  `mail_update_message`-Tools;
- `build_commit`, `build_configuration` und `version` in Diagnostics;
- Launch-Services-Backend für das signierte App-Bundle und loopback-only
  Streamable HTTP;
- Cloudflare-Access-Verifikation am Remote-MCP-Origin sowie explizite Browser-
  Origins;
- kein permanentes Delete, kein Leeren von Trash und kein Attachment-Export.

Die Bounded-Traversal-Aussage bezieht sich auf die von der Anwendung
angeforderten Collection-Elemente. Sie behauptet ausdrücklich nicht, dass
Mail.app intern für ein Apple Event niemals mehr Arbeit ausführt.

## Quality Gates

Alle folgenden Läufe waren erfolgreich:

```text
swift-format lint --recursive Sources Tests
git diff --check
git diff --cached --check
swift test                         84 Tests in 22 Suites
xcodebuild test                    83 Tests in 21 Suites, erfolgreich
bun run typecheck                  erfolgreich
bun test                            13 passed, 0 failed
bun run build                       erfolgreich
```

Der Xcode-Testlauf wurde mit einem Worker ausgeführt, damit der Xcode-Test-
Runner die Swift-Testing-Lifecycle-Tests deterministisch abarbeitet. Der
MCP-Vertragstest für `mail_send_message` lief dabei tatsächlich durch; ein
isolierter Methodenfilter, der zuvor null Tests gemeldet hatte, wird nicht als
Testnachweis verwendet.

Die SwiftPM- und Xcode-Suiten decken unter anderem opaque References, canonical
Inbox, bounded traversal, Sanitization, Read-/Send-Policy, MCP-Discovery,
Loopback-HTTP, Cancellation/Timeouts, synthetic Mail-Fixtures und die lokale
Mail.app-Read-Integration ab.

## Write-Gates

Es wurde keine echte Mail versendet und keine echte Draft-, Move-, Archive-,
Trash- oder Statusmutation ausgeführt. Das ist der korrekte Abschluss für die
vorliegende Umgebung: Es liegt keine explizit freigegebene sichere Testadresse
und keine separate Testkonfiguration vor. `send_mode=allowed` und
`mutation_mode=allowed` wurden deshalb nicht aktiviert. Reale Write-E2E-Tests
bleiben ein manueller Gate mit expliziter Freigabe, sicherer Testadresse bzw.
Testmailbox und bestätigter Mail.app-Identity.

`confirmation_required` bleibt bis zur Implementierung einer echten
Confirmation-Grenze blockiert; ein Tool-Aufruf darf diese Grenze nicht
umgehen.

## Artifact und Deployment

Das ausgelieferte App-Bundle wird aus dem sauberen Abschluss-Commit gebaut.
Die Provenance-Prüfung des ausgelieferten Debug-Bundles ergab:

```text
CFBundleShortVersionString: 0.1.0
CFBundleVersion: 1
ApplePlatformMCPBuildCommit: exakter Abschluss-Commit
ApplePlatformMCPBuildConfiguration: Debug
NSAppleEventsUsageDescription: vorhanden
```

Genau dieses Bundle liegt unter
`<private local path>/Applications/apple-platform-mcp.app`; das vorherige Bundle
ist als `<private local path>/Applications/apple-platform-mcp.app.previous-20260826-0315`
recoverbar. Der LaunchAgent `<private LaunchAgent identifier>` wurde
nach dem kontrollierten Bundle-Update neu geladen. Der laufende App-Prozess
liefert über `mail_server_info` den Commit `d741405e738e3eae871362b05c42286b6a8e08ac`,
`Debug`, Version `0.1.0`, `send_mode=denied`, `mutation_mode=denied`,
`mailbox_mutations=true`, `computer_use=false` und `accessibility=false`.

## Remote-E2E

Der Remote-Gateway-Code und seine Tests sind grün. Der tatsächlich geladene
lokale LaunchAgent-Pfad wurde sicher verifiziert:

```text
healthz
readyz
MCP initialize
tools/list
mail_server_info
```

`/healthz` und `/readyz` lieferten jeweils `200`; der lokale App-Liveness-
Endpoint lieferte `200`; `tools/list` und `mail_server_info` antworteten über
die neue App. Dabei wurde kein Mailbox-Inhalt gelesen, keine Mutation und kein
Versand ausgelöst. Die lokale Tool-Liste enthält die fünf Read-Tools, die
Send-Fähigkeit sowie die fünf separat policy-gesteuerten Draft-/Mailbox-
Mutationstools.

Der öffentliche Cloudflare-Host `<private Cloudflare Access endpoint>` ist erreichbar und
liegt hinter Access. Unauthenticated `healthz` und MCP-Requests liefern `401`,
und die vorhandene Browser-Sitzung enthält keine Access-Anmeldung. Der
Cloudflare-Login würde einen E-Mail-Code anfordern. Dieser Code wurde nicht
angefordert und keine Adresse oder Authentifizierungsinformation wurde
übermittelt. Deshalb bleiben authentifiziertes öffentliches `initialize`,
`tools/list` und `mail_server_info` als manueller Remote-Access-Gate offen.

## Git-Zustand

Dieser Bericht gehört in den Abschlusscommit. Der exakte Hash ist die
Provenance des ausgelieferten Bundles und wird im abschließenden Task-Handoff
genannt; nach dem Push muss der Working Tree sauber bleiben.

## IMAP-Entscheidung

**NO IMAP NEEDED FOR V1.** Die Kern-Workflows bleiben Mail.app-only. Broad
Archive Search ist eine explizite Fähigkeit ohne harte V1-Latenzgarantie und
kein Grund, innerhalb dieses V1-Abschlusses ein zweites Backend einzuführen.
