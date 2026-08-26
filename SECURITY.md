# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting or security advisory workflow for this
repository. If private reporting is unavailable, contact the repository owner
through a private GitHub channel before sharing details publicly.

Include:

- the affected commit or release;
- a concise impact statement and reproduction steps;
- the smallest source or configuration example needed to validate the issue;
- any required deployment assumptions.

Do not include Mail message content, Cloudflare JWTs, capability tokens,
provider credentials, signing material, or private host configuration in a
report. Redact those values before submitting evidence.

## Scope notes

The security boundary includes the Swift MCP server, its Mail.app Apple Events
adapter, the optional remote gateway, and the release/deployment configuration
that connects them. Mail.app, macOS, Cloudflare, GitHub Actions, and provider
services remain external trust boundaries.

The server intentionally defaults to read-only behavior. A report that relies
on an operator explicitly enabling a mutation policy should state that
prerequisite and the exact capability it enables.
