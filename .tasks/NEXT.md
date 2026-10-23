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

## TASK-013: Complete iCloud eviction and second-device acceptance
**Priority:** P1 | **Tags:** files, icloud, live-verification

Complete the external acceptance gates remaining after TASK-012's implementation
and signed local transport verification. Deployment remains a separate step.

### Plan

- Use a dedicated disposable fixture inside the approved HighByteTech root;
  keep the installed root/write policy unchanged and do not alter existing user documents.
- Obtain a genuinely evicted test file. After the provider reports NotDownloaded,
  verify retryable bounded reads, request download, then compare text/binary bytes.
- Independently observe the fixture on another signed-in device; record downloaded
  binary SHA-256 and text evidence separately from local upload status.
- Update the evidence record and mark acceptance complete only after both gates pass.

### Current evidence

The combined Mac mini release is deployed (TASK-015): 195 Swift tests and 18
gateway tests passed, and live HighByteTech-only read access was verified. Earlier
eviction requests still reported Current; real evicted-file re-download and an
independent byte-for-byte sync observation remain unverified. Use the now-available
Mac mini and development Mac for that separate acceptance, within HighByteTech only.

---
