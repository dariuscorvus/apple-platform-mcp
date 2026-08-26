# Next

## TASK-002: Verify authenticated Cloudflare and ChatGPT end-to-end access
**Priority:** P0 | **Tags:** e2e, cloudflare, chatgpt, security

Validate the public MCP route through Cloudflare Access from the ChatGPT app.
Confirm that the authenticated `tools/list` result matches the intended
policy-gated server surface without exposing tokens or Mail content.

### Plan

- Verify the Cloudflare Access configuration and protected MCP endpoint.
- Complete the ChatGPT authentication flow and compare `tools/list` with the
  deployed server policy.
- Run a read-only smoke test and capture non-sensitive evidence.

### Current evidence

- The local gateway is live and ready; unauthenticated local and public MCP
  requests are rejected with `401`.
- The Cloudflare Tunnel process is running, its ingress configuration validates,
  and it has a route to the loopback gateway.
- The remaining step requires an interactive Cloudflare Access sign-in from
  the ChatGPT app before authenticated `tools/list` can be verified.

---

## TASK-003: Protect the public main branch and release controls
**Priority:** P1 | **Tags:** governance, github, ci, release

Require the green CI workflow before changes reach `main` and keep the public
repository's release process reviewable.

### Plan

- Inspect the current GitHub ruleset and CI status-check names.
- Require CI for `main` and preserve administrator recovery access as needed.
- Verify that direct pushes and pull requests follow the configured rule.

### Current evidence

- `main` now requires the strict `release`, `remote`, and `xcode` checks;
  force-pushes and branch deletion are disabled and conversations must be
  resolved.
- Administrator enforcement remains off for explicit recovery by the sole
  maintainer. The remaining acceptance check is the next real pull request.

---
