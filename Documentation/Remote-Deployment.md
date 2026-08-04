# Remote deployment with Cloudflare Access

This guide exposes the local Apple Platform MCP server to remote MCP clients
such as Claude and ChatGPT without moving Mail.app access off the Mac or
opening a router port. It follows the same boundary as the sibling
`obsidian-cli-mcp` deployment:

```text
Claude or ChatGPT
    |
    | HTTPS + OAuth
    v
Cloudflare Access Managed OAuth
    |
    | signed Access JWT
    v
Cloudflare Tunnel
    |
    | http://127.0.0.1:3766 only
    v
Remote Streamable HTTP gateway
    |
    | stdio
    v
Signed Apple Platform MCP executable
    |
    v
Mail.app through ScriptingBridge and Apple Events
```

The Swift server remains a local stdio process. The gateway is a small Bun or
Node process that forwards MCP discovery and tool calls. Mail content is still
subject to the local read-only policy, limits, and sanitization.

## Security boundary

- Keep the gateway on `127.0.0.1`. Do not bind it to `0.0.0.0` for this setup.
- Protect the public hostname with Cloudflare Access.
- Configure the gateway with both the Access team domain and application
  audience. It verifies the Access JWT again at the origin.
- Set an explicit `APPLE_PLATFORM_MCP_HTTP_ORIGINS` list for browser clients.
- Do not commit tunnel credentials, Access audience values, token files, or
  user-specific launchd plists.
- The gateway exposes only the existing read-only tool catalog. It does not
  add send, delete, draft, attachment export, or arbitrary code execution.

Cloudflare Access Managed OAuth performs the public OAuth flow. The gateway
does not implement a second OAuth server. It validates the assertion that
Cloudflare adds after the request passes Access policy.

## 1. Prerequisites

- macOS 13 or newer with Mail.app available
- a signed Apple Platform MCP app build
- Mail.app open in the same user session as the gateway
- Automation permission for the signed app bundle
- Bun or Node 18 or newer
- a Cloudflare-managed DNS zone and `cloudflared`
- a dedicated hostname such as `mcp.example.com`

Build and diagnose the local app before adding the network boundary:

```sh
xcodebuild \
  -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$HOME/.jcode/scratch/apple-platform-mcp.xcarchive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application: <name> (<team>)' \
  DEVELOPMENT_TEAM='<team>' \
  archive

APP="$HOME/.jcode/scratch/apple-platform-mcp.xcarchive/Products/Applications/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp"
"$APP" doctor --request-automation
```

Use the exact executable path from the archive. The gateway needs the embedded
executable, not an unsigned copy or a shell wrapper.

## 2. Build the gateway

```sh
cd Remote
bun install --frozen-lockfile
bun run typecheck
bun test
bun run build
```

The bundled entry point is `Remote/dist/main.js`. It can be run with Bun or a
Node runtime that supports the bundled output:

```sh
node /absolute/path/to/apple-platform-mcp/Remote/dist/main.js
```

## 3. Configure the local gateway

Set the following environment variables in the gateway process. The Access
values are public identifiers, not passwords, but still keep deployment
configuration outside the repository.

```sh
export APPLE_PLATFORM_MCP_EXECUTABLE="$HOME/.jcode/scratch/apple-platform-mcp.xcarchive/Products/Applications/apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp"
export APPLE_PLATFORM_MCP_HTTP_HOST=127.0.0.1
export APPLE_PLATFORM_MCP_HTTP_PORT=3766
export APPLE_PLATFORM_MCP_HTTP_PATH=/apple-platform
export APPLE_PLATFORM_MCP_HTTP_ORIGINS=https://claude.ai,https://chatgpt.com
export APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN=YOUR_TEAM.cloudflareaccess.com
export APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE=YOUR_ACCESS_APPLICATION_AUD
export APPLE_PLATFORM_MCP_CF_ACCESS_EMAIL=you@example.com

node /absolute/path/to/apple-platform-mcp/Remote/dist/main.js
```

Optional variables:

| Variable | Purpose |
| --- | --- |
| `APPLE_PLATFORM_MCP_ARGUMENTS_JSON` | JSON array of arguments passed to the Swift executable. Default: `[]`. |
| `APPLE_PLATFORM_MCP_WORKING_DIRECTORY` | Working directory for the Swift child process. |
| `APPLE_PLATFORM_MCP_HTTP_HOST` | Listener address. Keep this `127.0.0.1`. |
| `APPLE_PLATFORM_MCP_HTTP_PORT` | Local listener port. Default: `3766`. |
| `APPLE_PLATFORM_MCP_HTTP_PATH` | Exact MCP path. This deployment uses `/apple-platform`; the code default is `/mail`. |
| `APPLE_PLATFORM_MCP_REQUEST_TIMEOUT_MS` | Maximum backend request wait. Defaults to `60000`; accepts `100` to `600000`. |
| `APPLE_PLATFORM_MCP_HTTP_ORIGINS` | Comma-separated browser origin allowlist. |

The local endpoints are:

```text
GET  http://127.0.0.1:3766/healthz
GET  http://127.0.0.1:3766/readyz
POST http://127.0.0.1:3766/apple-platform
```

`/readyz` sends a live MCP ping to the Swift child. It does not read message
content and detects a closed stdio connection instead of trusting the cached
tool list. The backend clears its cache and reconnects with a fresh child
client after a transport close. Request cancellation from the remote client is
also forwarded to the local MCP request. The MCP path is exact, so
`/apple-platform/anything` and other paths return 404.

## 4. Create the Cloudflare Tunnel

Install and authenticate `cloudflared`, then create a named tunnel and DNS
route:

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create apple-platform-mcp
cloudflared tunnel route dns apple-platform-mcp mcp.example.com
```

Create `~/.cloudflared/config.yml` from
`Examples/remote/cloudflared-config.yml.example`:

```yaml
tunnel: TUNNEL_UUID
credentials-file: /Users/YOU/.cloudflared/TUNNEL_UUID.json

originRequest:
  connectTimeout: 10s
  noTLSVerify: false

ingress:
  - hostname: mcp.example.com
    service: http://127.0.0.1:3766
    originRequest:
      access:
        required: true
        teamName: YOUR_ACCESS_TEAM_NAME
        audTag:
          - YOUR_ACCESS_APPLICATION_AUD
  - service: http_status:404
```

Validate the route:

```sh
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://mcp.example.com/mail
```

The final 404 rule is intentional. Do not add a catch-all route to another
local service.

## 5. Configure Cloudflare Access Managed OAuth

In **Cloudflare Zero Trust -> Access -> Applications**, create a self-hosted
application for the whole hostname `mcp.example.com`. Cloudflare Access
application domains should contain the hostname, not `/mail`.

Recommended settings:

1. Permit only the intended identity or email address.
2. Enable **Managed OAuth**.
3. Enable Dynamic Client Registration when the target client requires it.
4. Require PKCE with `S256`.
5. Use a short Access token lifetime and a bounded login session.
6. Copy the application **AUD** value into
   `APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE` and the tunnel's `audTag` list.
7. For a locally managed tunnel, enable `originRequest.access` on the published
   hostname with the Access team name and application AUD. This makes
   `cloudflared` validate the Access JWT before forwarding to the gateway.

Register only the callbacks needed by the clients you will use:

- Claude: `https://claude.ai/api/mcp/auth_callback`
- ChatGPT, least privilege: the app-specific callback shown by ChatGPT,
  usually `https://chatgpt.com/connector/oauth/{callback_id}`
- ChatGPT, private single-user convenience: `https://chatgpt.com/connector/oauth/*`

Prefer the exact ChatGPT callback for a multi-user deployment. Never broaden
the callback to all of `chatgpt.com`, and do not allow non-HTTPS callbacks.

Cloudflare should publish the protected-resource and authorization-server
metadata for the hostname. The public MCP URL to register is:

```text
https://mcp.example.com/mail
```

Do not append a capability token when using Cloudflare Access mode.

## 6. Connect Claude

In Claude, add a custom connector or remote MCP server using:

```text
https://mcp.example.com/mail
```

Complete the Cloudflare Access login and OAuth consent flow. Claude should send
the Access assertion to the gateway after authentication. If discovery fails,
check the Access application, callback, hostname, and the local
`/readyz` endpoint before changing the MCP path.

### Current Cloudflare Access caveat

Cloudflare Managed OAuth requires the RFC 8707 `resource` parameter on the
authorization request. As of August 2026, Claude.ai hosted custom connectors
may omit that parameter for Cloudflare Access Managed OAuth and fail with
`invalid_target` or `Multiple resources not supported` after the connector is
added. This is a client/provider interoperability issue, not a gateway
readiness failure. Use a client that sends the resource indicator, or use an
OAuth provider that does not require it, until Claude resolves the upstream
issue. The endpoint remains protected and usable by compliant MCP clients.

## 7. Connect ChatGPT

In ChatGPT, add a connector or app using the same public MCP URL:

```text
https://mcp.example.com/mail
```

Use the exact callback displayed by ChatGPT when configuring the Access
application. Complete the Access login and consent flow, then verify that the
connector lists `mail_server_info` and the other read-only tools.

ChatGPT custom MCP apps require Developer Mode and a workspace plan that
supports full MCP connectors, such as Business, Enterprise, or Edu. Individual
Pro accounts may not expose the custom-app registration controls. In that case
the public endpoint is still ready for a supported ChatGPT workspace or another
RFC 8707-compliant MCP client.

## 8. Connect Codex directly

Codex can use a streamable HTTP MCP server directly. It does not need a separate
Claude or ChatGPT connector plugin. Register the exact public MCP path, not only
the hostname:

```sh
codex mcp add apple-platform-mcp \
  --url https://mcp.example.com/mail
```

For an existing entry, the equivalent `~/.codex/config.toml` block is:

```toml
[mcp_servers.apple-platform-mcp]
enabled = true
url = "https://mcp.example.com/mail"
```

See `Examples/mcp-client-configs/codex-config.toml.example` for a copy-ready
snippet.

The Cloudflare Access application still covers the whole hostname, but the MCP
URL and OAuth `resource` value must include the exact path. Authenticate the
entry with Codex's PKCE flow:

```sh
codex mcp login apple-platform-mcp
```

The command opens the Access authorization URL and returns through Codex's local
OAuth callback. Verify the registered URL and run a read-only smoke test:

```sh
codex mcp get apple-platform-mcp
codex exec --ephemeral --sandbox read-only --json \
  'Use the configured apple-platform-mcp server. Invoke only the read-only tool mail_server_info. Do not call any other tool and do not modify files.'
```

The expected result is a successful `mail_server_info` response with
`mode: "read_only"`. Do not use the hostname root as the MCP URL when the
gateway is configured on a path.

## 9. Keep the services running with launchd

Use user LaunchAgents in `~/Library/LaunchAgents/`, not system LaunchDaemons.
The signed app needs the logged-in GUI user session for Mail.app and Apple
Events.

Copy the examples and replace every placeholder:

```sh
cp Examples/remote/launchd/codes.example.apple-platform-mcp-remote.plist.example \
  ~/Library/LaunchAgents/codes.example.apple-platform-mcp-remote.plist
cp Examples/remote/launchd/codes.example.apple-platform-mcp-tunnel.plist.example \
  ~/Library/LaunchAgents/codes.example.apple-platform-mcp-tunnel.plist

plutil -lint ~/Library/LaunchAgents/codes.example.apple-platform-mcp-remote.plist
plutil -lint ~/Library/LaunchAgents/codes.example.apple-platform-mcp-tunnel.plist
chmod 644 ~/Library/LaunchAgents/codes.example.apple-platform-mcp-*.plist

launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/codes.example.apple-platform-mcp-remote.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/codes.example.apple-platform-mcp-tunnel.plist
```

The gateway plist uses `KeepAlive` and writes logs under
`~/Library/Logs/`. The tunnel plist supervises `cloudflared` separately. Never
put the tunnel credential JSON, a capability token, or a private signing key
in a committed plist.

To reload after an edit:

```sh
launchctl bootout gui/$(id -u)/codes.example.apple-platform-mcp-remote 2>/dev/null || true
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/codes.example.apple-platform-mcp-remote.plist
launchctl print gui/$(id -u)/codes.example.apple-platform-mcp-remote
```

## 10. Private token mode for local testing

Cloudflare Access is the recommended public deployment. For a private test
without Cloudflare, create a mode-600 token file containing at least 32 random
characters:

```sh
umask 077
openssl rand -hex 32 > "$HOME/.config/apple-platform-mcp/http-token"

export APPLE_PLATFORM_MCP_HTTP_TOKEN_FILE="$HOME/.config/apple-platform-mcp/http-token"
unset APPLE_PLATFORM_MCP_CF_ACCESS_TEAM_DOMAIN
unset APPLE_PLATFORM_MCP_CF_ACCESS_AUDIENCE
unset APPLE_PLATFORM_MCP_CF_ACCESS_EMAIL
```

The endpoint becomes `/mail/<encoded-token>`. This mode is intentionally not a
replacement for OAuth and should not be put behind a public hostname. Do not
log or paste the resulting URL into shared chat.

## 11. Troubleshooting

Check the local layers from the Mac running the gateway:

```sh
curl -fsS http://127.0.0.1:3766/healthz
curl -fsS http://127.0.0.1:3766/readyz
tail -f "$HOME/Library/Logs/apple-platform-mcp-remote.error.log"
tail -f "$HOME/Library/Logs/apple-platform-mcp-tunnel.error.log"
```

Common failures:

- `doctor` reports missing Automation permission: approve the signed app in
  **System Settings -> Privacy & Security -> Automation**, then retry.
- `/readyz` is unavailable: inspect the gateway executable path, the Swift
  child stderr, Mail.app state, and the local MCP build.
- Cloudflare returns an Access page: verify the Access policy and callback
  before debugging MCP.
- The gateway returns 401: verify the team domain, Access audience, optional
  email, and that the request includes `Cf-Access-Jwt-Assertion`.
- The gateway returns 403: add the exact client browser origin to
  `APPLE_PLATFORM_MCP_HTTP_ORIGINS`.
- The tunnel is healthy but MCP discovery is 404: use the exact configured
  `/mail` path and keep the Cloudflare Access application on the hostname.
