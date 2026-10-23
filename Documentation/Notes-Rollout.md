# Signed Notes rollout

TASK-014 is **in progress**. The signed app is installed and live gateway tests pass;
actual connected-client acceptance is pending. See [live evidence](Notes-Rollout-Evidence.md).

A passing synthetic test is not permission, signing,
live Notes, gateway, or connected-client evidence.

## Initial preparation (2026-10-17)

- Installed app: `~/Applications/apple-platform-mcp.app`, bundle identifier
  `com.dariuscorvus.apple-platform-mcp`; current signature is ad hoc, no team.
- No valid signing identity was present at the last preflight. Xcode first-launch
  check exited 69. Complete setup/license acceptance and Apple-Developer sign-in
  interactively. The operator confirmed an active Developer membership.
- The desktop was locked when UI setup was attempted; unlock it before continuing.
- Existing app and configuration are backed up under the private directory
  `~/.local/state/apple-platform-mcp/notes-rollout/20261016T222333Z/`.
  `manifest.json` records the previous executable hash. Config copies are mode 0600;
  the directory is mode 0700. Never commit this directory or its contents.
- Two isolated configs exist there: `isolated-allowed.json` permits only Notes
  creation; `isolated-denied.json` keeps every mutation denied.
- 140 Swift tests, 10 synthetic rollout tests, and external stdio discovery passed.
  The latter verifies the new executable/catalog without accessing Notes data.

## Identity and candidate

In Xcode Settings → Accounts, select the existing paid Developer team and use
Manage Certificates to create/download **Developer ID Application**, including its
private key in the local keychain. A team administrator may need to perform this
step. Do not revoke existing certificates or export private keys into the repo.
The operator performs account authentication, license/contract acceptance, and
any credential entry. An Apple Development or ad-hoc certificate does not satisfy
this rollout.

Run the non-mutating preflight:

```sh
python3 Scripts/build-signed-notes-candidate.py
```

Once ready, choose a **new** private output directory:

```sh
python3 Scripts/build-signed-notes-candidate.py --build \
  --output "$HOME/.local/state/apple-platform-mcp/notes-rollout/signed-candidate-01"
```

When multiple Developer ID identities exist, supply `--identity` with the exact
SHA-1 fingerprint from `security find-identity -v -p codesigning`; confirm the
intended team with the operator. The script archives Release with manual signing,
verifies the bundle ID, Developer ID authority, team, Hardened Runtime, and exact
Apple Events entitlement, then records source and executable SHA-256 hashes.
It rejects missing prerequisites and never installs or restarts the service.
Use `--derived-data <existing-private-DerivedData>` to reuse the build cache
when producing a corrected candidate; each candidate archive/output remains distinct.
`candidate.json` distinguishes the current Git HEAD from a dirty source tree.
The local artifact is not notarized and must not be described as a public release.

## Isolated acceptance

Use the app path in `candidate.json`; do not invoke the installed production app.
Open Notes manually and run the candidate executable with `doctor --request-notes`.
The operator allows the Notes Automation prompt. Require `notes_permission=allowed`.
Use the candidate's existing Mail and Reminders doctors to check their independent
permissions as well; re-grant those only as required for the new stable identity.

**Host identity matters:** CLI acceptance does not prove the Launch Services host
has consent. Launch setup for the installed background host through `/usr/bin/open`
with `-W -n -g --stdout <private-output> --stderr <private-errors> <app-bundle>`
followed by `--args doctor --request-notes` (or `--request-reminders`). Precreate
the output files with mode 0600. After consent, restart the backend/gateway before
checking EventKit again. Always verify adapter access through the actual gateway.

1. Run `verify-notes-live-smoke.py --binary <candidate-executable> --config
   <absolute-isolated-allowed-config> --discover`. Keep discovery output private.
2. If multiple accounts exist, ask the operator to select one. In Notes UI create
   a new **non-shared** folder `Apple Platform MCP Live Test` in that account.
   If a folder already has that name, use a timestamp suffix instead of reusing it.
3. Save the exact selected account reference in a private text file; repeat
   discovery with `--account-reference-file <file>` to list its folders. Match the
   newly created folder and save its exact reference in another private text file.
4. Run the allow test with a fresh journal in the private rollout directory:

   ```sh
   python3 Scripts/verify-notes-live-smoke.py \
     --binary <candidate-executable> --config <absolute-isolated-allowed-config> \
     --folder-reference-file <absolute-private-folder-reference-file> \
     --journal <absolute-private-directory>/isolated-allow.json --confirm-live
   ```

5. Run again with the denied configuration, a separate fresh journal, and
   `--mode denied`. This must report `denial_verified` and leave no new note.
6. Inspect only the exact synthetic note/title recorded in the allow journal in
   Notes UI. Check umlauts, line breaks and literal HTML metacharacters. Keep the
   note and folder; record visual verification separately.

The allow run creates a unique title, repeats the exact request in the same MCP
process, reads it back, and requires exactly one search result. It never edits or
deletes notes. The journal is reserved atomically before dispatch. Existing journal
paths refuse to rerun, even after a successful prior run. After failure, inspect
the journal and folder before considering a new run/key. Never infer that a timeout
means creation failed. A journal marked `mcp_verified_visual_check_pending` still
needs the Notes UI check and does not establish client/gateway acceptance.

## Controlled deployment

Do not deploy until candidate signing, isolated allow/deny, visual checks and
Mail/Reminders permission checks are recorded as passed.

- Recheck the candidate executable hash against `candidate.json` and ensure the
  production app/config still match the backed-up baseline. If either changed,
  inspect the change and take a fresh backup before proceeding.
- Stop the exact gateway LaunchAgent
  `gui/$(id -u)/codes.darius.apple-platform-mcp-remote`, then terminate only the
  backend whose executable path matches the installed app. Wait for it to exit.
  Leave Cloudflare and the Mail watchdog running.
- Replace the app using a staged same-volume rename; preserve the old bundle as
  a rollback copy. Merge only `notes_mutation_mode=allowed` into the current JSON
  config with an atomic write, preserving all other values and restrictive mode.
- Bootstrap the existing gateway LaunchAgent from its existing local plist. Let
  its Launch Services backend start the installed signed app. Verify the running
  process path, executable hash, identity, `/healthz` and `/readyz`.
- Through the authenticated existing gateway, discover all five Notes tools,
  check Notes policy, and run the allow smoke with a **second** journal/title in
  the same test folder. The harness accepts `--url http://127.0.0.1:3766/apple-platform`
  and an optional `--headers-file` (mode 0600) with `Authorization` or
  `Cf-Access-Jwt-Assertion`. It refuses remote URLs and redirects. It never obtains
  credentials or disables gateway authentication. A Cloudflare deployment needs a
  valid existing authenticated assertion; lack of one remains a separate gate.
- Verify Mail account discovery and Reminders list discovery without outputting
  their private names/content. A gateway ping alone does not establish adapter
  permission or healthy Notes access.
- Refresh the connected client's MCP tool catalog using its supported interface.
  Require actual client discovery and a read of the exact synthetic test note;
  record this independently of local and gateway checks. No public endpoint or
  new authentication mode is introduced for testing.

## Rollback and evidence

For a failed post-install check, stop gateway and the exact installed backend,
restore the retained previous bundle and saved config, then bootstrap the existing
LaunchAgent. Verify executable hash, readiness and Mail/Reminders permissions.
A signature transition can require renewed TCC consent even during rollback.
Keep synthetic Notes data; do not clean it up through a guessed reference.

Record only hashes, test identifiers, signature/team metadata, pass/fail gates,
and sanitized errors in repository evidence. Raw configuration, auth headers,
account/folder names, references and detailed journals stay private. Mark TASK-014
Done and add the completion work-log entry only after signed runtime, TCC,
isolated acceptance, gateway and actual connected-client checks have passed.
