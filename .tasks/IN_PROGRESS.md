# In Progress

## TASK-001: Sign and notarize the release-candidate artifact
**Priority:** P0 | **Tags:** release, signing, notarization

Produce a reproducible macOS release candidate from `main`. Keep Developer ID
and notarization credentials outside the repository and publish only a
verified artifact with its checksum.

### Plan

- Audit the available Developer ID and notarization prerequisites.
- Build, sign, notarize, staple, and validate the app/DMG.
- Record the artifact version, commit, checksum, and verification evidence.

### Current evidence

- The Release configuration enables Hardened Runtime and only requests the
  Apple Events entitlement required by the Mail.app adapter.
- The release workflow contains archive, signature verification, DMG,
  notarization, stapling, and GitHub-release steps.
- This Mac has no valid Developer ID identity, and the public repository has
  no signing or Notary secrets; an unsigned workflow dry run is required to
  validate the credential-independent path.
- Workflow dispatch run `32944937673` completed successfully: tests, universal
  archive, DMG creation, and artifact upload passed; credential-gated steps
  were skipped as designed.
- The downloaded unsigned DMG has SHA-256
  `f8b58529bd9205524a7473155566dc1dc467572c3f22c0e91a3a345296bd41e8`.
  It is ad-hoc signed and has no stapled ticket, which is correct for this
  dry run but not a release candidate.
- The release workflow now records `GITHUB_SHA` in the app bundle and ships a
  SHA-256 sidecar. A local universal archive verified the commit field is
  embedded in `Info.plist`.
- The repository now has a dedicated `release` GitHub Environment; it is empty
  by design. The remaining protected secrets are `APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
  `APPLE_PASSWORD`, and `APPLE_TEAM_ID`.

---
