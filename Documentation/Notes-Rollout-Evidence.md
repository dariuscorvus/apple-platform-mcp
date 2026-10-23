# Notes live rollout evidence — 2026-10-17

**Installed and live-tested; actual ChatGPT client acceptance remains pending.**
TASK-014 stays In Progress until that final gate is verified.

## Installed artifact

- App: `~/Applications/apple-platform-mcp.app`
- Bundle ID: `com.dariuscorvus.apple-platform-mcp`
- Configuration: Release; Developer ID Application; Hardened Runtime enabled
- Team ID: `4WF4549NW5`
- Signing certificate SHA-1: `F9B4EDD174E886C3B8BEB43A7E5EBFB78B23424C`
- Executable SHA-256:
  `9207778541f909ec6a4acad60899ed78251c25d323b72480f263001de09316b8`
- Build-input SHA-256:
  `448baaf72a655316ea2fb8f0af4de6772c3ae2302e66ec8a2f2b4a6d563c5582`
- Base Git HEAD: `e94e85928167b7f123e22c317f5e2aa09f978b51`
- Built from the working tree, including uncommitted changes; the base commit
  alone does not identify the deployed source. No source publication was performed.
- `codesign --verify --deep --strict` passes on the installed app.
- Signed entitlement set: `com.apple.security.automation.apple-events=true`.
- CFBundleExecutable explicitly identifies `apple-platform-mcp`; app signature
  verification also passes on a staged bundle with a different directory name.
- Notarization/public distribution was outside this rollout.

## Acceptance results

| Gate | Evidence/result |
| --- | --- |
| Full Swift suite | 142 tests in 35 suites passed, including stable-reference regressions and local Mail read integration |
| Rollout runner guardrails | 10 Python tests passed |
| Isolated signed Notes | Create, identical-key retry, stable references, search and plaintext read passed |
| Default-denied creation | `notesPolicyDenied`; search confirms no note created |
| Notes visual inspection | Exact synthetic fixture selected in Notes; umlauts, line breaks and literal HTML metacharacters confirmed |
| Actual Launch Services host | Notes Automation and Reminders Full Access explicitly granted; Mail Automation allowed |
| Installed authenticated gateway | Five Notes tools discovered; create/retry/read/search passed |
| After permission-refresh restart | Same gateway fixture remains readable; no create repeated across restart |
| Existing adapters | Authenticated gateway Mail account and Reminders list discovery succeeded |
| Gateway health/readiness | Both HTTP 200 |
| Unauthenticated local gateway | HTTP 401 |
| Public Cloudflare endpoint | Authenticated initialize/tools-list and read of exact gateway fixture passed |
| Connected ChatGPT app | **Not passed:** both existing links still return reauthentication required; Notes tools absent from this chat's advertised catalog |

Only `notes_mutation_mode=allowed` was merged into the existing production
configuration. Other policy values and file permissions were preserved.
Cloudflare, gateway authentication and listener exposure were not broadened.

## Live findings fixed before deployment

1. Default JSON key order made equivalent opaque Notes references differ between
   discovery and reads. Sorted-key encoding now makes them canonical; existing
   unsorted references remain decodable. Both encoding and cross-tool identity
   regression tests pass.
2. Missing CFBundleExecutable caused a renamed staging bundle to be interpreted
   incorrectly during signature verification. Explicit executable metadata and
   candidate validation now prevent that packaging mistake.
3. Direct CLI consent did not establish Notes/Reminders permission for the actual
   Launch Services host. The installed app's setup commands were launched through
   Launch Services, user consent was obtained, and the backend/gateway restarted
   before the final adapter checks.

## Fixtures, private evidence and rollback

Four distinct synthetic test notes remain in the dedicated non-shared test folder:

- first candidate: creation/read confirmed, reference-instability finding retained;
- canonical-reference candidate: isolated acceptance passed;
- final packaged candidate: isolated acceptance passed;
- installed gateway: create/retry/read/search and post-restart read passed.

Each deliberate create run generated one note; same-process retries did not
produce additional notes. Denied-write runs generated none. Existing notes were
not edited, moved or deleted.

Private journals, opaque references, configs, temporary auth headers and full
build/doctor output are under:
`~/.local/state/apple-platform-mcp/notes-rollout/` (private directory).
Do not commit their contents. The original app/config backup is in its
`20261016T222333Z` subdirectory. The prior installed bundle is also retained at
`~/Applications/.apple-platform-mcp.pre-notes-20261017.app`.
Restore it to the original app name/path before verifying or running it; its
legacy plist lacks an explicit executable key. Rollback can require renewed TCC
consent because the old artifact is ad hoc signed.

## Remaining client gate

Reconnect the existing Apple Platform Mail connection, refresh its metadata, and
verify the five `notes_*` tools in ChatGPT. Then read the exact synthetic gateway
fixture (run marker `740dad063d864ad3927d9a7d8ee557a8`) through that client.
No further creation is required for this final check.

OpenAI's documented refresh flow requires refreshing the connection after server
metadata changes, then testing in a new conversation. See
[Connect and test your plugin](https://developers.openai.com/plugins/deploy/connect-chatgpt).
The desktop client could not be controlled through computer use because that
app target is disallowed; no alternate control mechanism was used.
