# Best practice: scoped Apple MCP connections

Use one MCP connection per Apple service, with a stable URL and a small,
service-specific tool catalog. The gateway exposes these connections over the
same listener, authenticated tunnel and native Mac backend:

| Connection | Cloudflare Access URL | Tool prefix | Current tools |
| --- | --- | --- | ---: |
| Apple Mail | `https://mcp.example.com/apple/mail` | `mail_` | 11 |
| Apple Reminders | `https://mcp.example.com/apple/reminders` | `reminder_` | 10 |
| Apple Notes | `https://mcp.example.com/apple/notes` | `notes_` | 5 |
| Apple Calendar | `https://mcp.example.com/apple/calendar` | `calendar_` | 6 |
| Apple Contacts | `https://mcp.example.com/apple/contacts` | `contacts_` | 3 |
| Apple iCloud Drive | `https://mcp.example.com/apple/icloud` | `icloud_` | 16 |

Replace the example hostname with the deployment's hostname. No separate Swift
process, macOS permission grant or iCloud root configuration is needed per URL.
These routes are remote-gateway connections; native HTTP `/mcp` and stdio retain
the full catalog.

## Scope is enforced, not just described

Each connection has its own MCP server identity and instructions. `tools/list`
returns only tools with that area's prefix. Every `tools/call` must have both
the matching prefix and an exact entry in the backend catalog; foreign and
unknown tools fail with JSON-RPC InvalidParams before backend invocation.
For example, `/apple/contacts` cannot call `mail_send_message`.

Every route retains the configured origin checks and authentication. Cloudflare
assertions are verified with the existing audience and optional identity check.
In capability-token mode, the URL is `/apple/<area>/<encoded-token>`; a bare
area URL is unavailable. Keep such URLs private and out of logs and examples.
Paths match exactly: case variants, encoded aliases, dot segments, trailing
slashes and extra path components do not expose a scoped connection.
The `/apple` namespace is reserved and cannot be the configured legacy path.

## Agent configuration

Register the six URLs as separately named MCP connections. Enable only the
connections needed for a task: Contacts plus Calendar for scheduling, Mail for
mail work, iCloud Drive for files. A multi-service workflow can enable several.

Smaller selected catalogs can reduce irrelevant tool exposure and simplify tool
selection. Enabling all six still exposes the same aggregate tool set; token,
latency or accuracy improvements depend on the client and are not guaranteed.
Use short skills for workflows and domain conventions, such as choosing a
calendar, checking conflicts, or committing a chunked upload. Skills supplement
these catalog boundaries; they do not implement access control.

## Authentication and policy limits

The six routes share the configured authentication identity/audience. Separate
URLs are not separate user permissions: an identity authorized for the shared
Access application can reach the other routes too. The native server still
checks mutation policy, allowlists, permissions, revisions and idempotency.
Contacts stays read-only. iCloud access stays within configured roots, with
independent write/Trash gates. Local file success does not prove cloud sync.

For deployments requiring identity-based separation between services, configure
and validate explicit per-service authorization at both the edge and origin;
the shared-audience routes alone do not provide that separation. Do not claim
least-privilege identity isolation merely because the URLs differ.

## Cloudflare and migration

Route all six paths to the same gateway. The hostname-wide ingress example in
[Remote deployment](Remote-Deployment.md) supports this layout. Confirm the
Access application's protected paths and Managed OAuth resource configuration
cover `/apple/*`, as well as any retained legacy URL, before registering clients.
Path-specific ingress or Access rules covering only the old endpoint must be
updated deliberately; a gateway update does not alter Cloudflare settings.

`APPLE_PLATFORM_MCP_HTTP_PATH` continues to select the legacy combined endpoint
(default `/mail`). Existing clients keep the complete catalog on that URL.
The six `/apple/*` routes are always additional and do not require six gateway
processes or changing that environment variable. Keep the legacy URL during
migration, move clients to scoped connections, and avoid enabling the legacy
connection alongside all six unless duplicate exposure is intentional.

## Verification and rollback

Run `bun run typecheck`, `bun test`, and `bun run build` in `Remote/`. HTTP
integration tests cover all six areas under both authentication modes,
cross-area calls, unknown tools, simultaneous connections, origin checks,
path aliases and legacy discovery. These use synthetic data and a verifier
fixture; they do not establish live Cloudflare deployment acceptance.

After deployment, authenticate against every public URL, check initialization
identity and `tools/list`, and attempt a harmless cross-area call that must be
rejected. Confirm unauthenticated requests fail, and verify the legacy URL if
still used. Preserve the previous gateway bundle for rollback. Rolling the
gateway back leaves native configuration and user data unchanged but removes
the new URLs; clients can temporarily use the retained legacy connection.
