# Mail.app-only V1 — Public Status

Stand: 2026-08-26

## Ergebnis

Mail.app bleibt der einzige Backend-, Account-, Credential- und Versand-Owner.
Der Server verwendet ScriptingBridge/Apple Events und verwaltet weder
IMAP-/SMTP-Credentials noch eine parallele Mail-Datenbank.

Die V1 publiziert kontrollierte Draft-, Move-, Archive-, Trash- und Status-
Tools. Mailbox-Mutationen bleiben ohne lokale Konfiguration durch
`mutation_mode=denied` gesperrt. `mail_send_message` bleibt separat durch
`send_mode=denied` gesperrt.

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

Die V1 wurde lokal mit folgenden Prüfungen validiert:

```text
swift-format lint --recursive Sources Tests
git diff --check
swift test
xcodebuild test
bun run typecheck
bun test
bun run build
```

## Sicherheits- und Policy-Grenzen

- Eine fehlende oder ungültige lokale Konfiguration fällt auf Read-only,
  `send_mode=denied` und `mutation_mode=denied` zurück.
- `mutation_mode=allowed` aktiviert die validierten Draft-/Mailbox-Mutationen
  gemeinsam; der Versand bleibt davon unabhängig gesperrt.
- `confirmation_required` bleibt fail-closed, solange keine separate
  Bestätigungsgrenze implementiert ist.
- Es gibt keine Operation für permanentes Löschen oder zum Leeren des Trash.
- Mail-Inhalt ist untrusted data und autorisiert niemals selbst eine Aktion.
- Die lokale HTTP-Anbindung bleibt auf Loopback begrenzt. Ein Remote-Gateway
  muss separat über Cloudflare Access oder einen Capability-Token authentisieren.

## Write-Gates

Es wurde keine echte Mail versendet und keine echte Draft-, Move-, Archive-,
Trash- oder Statusmutation als automatisierter Release-Test ausgeführt. Reale
Write-E2E-Tests bleiben ein manueller Gate mit expliziter Freigabe, sicherer
Testadresse bzw. Testmailbox und bestätigter Mail.app-Identity.

## Deployment- und Release-Hinweis

Konkrete Hostnamen, lokale Benutzerpfade, LaunchAgent-Details, Backup-Orte,
Logs, Access-Identitäten und lokale Policy-Dateien gehören nicht in dieses
Repository. Sie werden ausschließlich in der jeweiligen privaten
Deployment-Umgebung verwaltet.

Ein signierter und notarized macOS-Release benötigt zusätzlich eine Developer-
ID-Signierung, Notary-Credentials und einen erfolgreich validierten
Release-Workflow. Der Quellstand und der lokale Entwicklungsbetrieb sind davon
getrennt.

## IMAP-Entscheidung

**NO IMAP NEEDED FOR V1.** Die Kern-Workflows bleiben Mail.app-only. Broad
Archive Search ist eine explizite Fähigkeit ohne harte V1-Latenzgarantie und
kein Grund, innerhalb dieses V1-Abschlusses ein zweites Backend einzuführen.
