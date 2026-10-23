#!/usr/bin/env python3
"""Preflight or archive a Developer-ID Notes candidate; never installs/restarts it."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
DEVELOPER = "/Applications/Xcode.app/Contents/Developer"
BUNDLE_ID = "com.dariuscorvus.apple-platform-mcp"


def run(arguments: list[str], *, check=True) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, cwd=ROOT, env={**os.environ, "DEVELOPER_DIR": DEVELOPER},
                          text=True, capture_output=True, check=check)


def identities(output: str) -> list[tuple[str, str]]:
    return re.findall(r'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(([A-Z0-9]{10})\)"', output)


def digest_sources() -> str:
    digest = hashlib.sha256()
    files = [ROOT / name for name in ("project.yml", "Package.swift", "Package.resolved")]
    files += [p for directory in ("Sources", "Config") for p in (ROOT / directory).rglob("*") if p.is_file()]
    for path in sorted(files):
        digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--identity", help="Exact SHA-1 fingerprint from security find-identity")
    parser.add_argument("--derived-data", help="Reusable absolute build cache, outside the installed app")
    parser.add_argument("--output", help="New private candidate directory outside the installed app")
    args = parser.parse_args()
    available = identities(run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout)
    if args.identity:
        available = [item for item in available if item[0].lower() == args.identity.lower()]
    setup = run(["xcodebuild", "-checkFirstLaunchStatus"], check=False)
    blockers = []
    if setup.returncode:
        blockers.append("user_must_complete_xcode_license_and_first_launch")
    if not available:
        blockers.append("developer_id_application_identity_missing")
    elif len(available) != 1:
        blockers.append("select_exact_developer_id_fingerprint")
    if blockers:
        print(json.dumps({"status": "prerequisites_missing", "blockers": blockers}))
        return 2
    fingerprint, team = available[0]
    if not args.build:
        print(json.dumps({"status": "ready_to_build", "team_id": team, "identity_sha1": fingerprint}))
        return 0
    if not args.output:
        parser.error("--build requires --output")
    output = Path(args.output).expanduser().resolve()
    installed = Path.home() / "Applications/apple-platform-mcp.app"
    if output == installed or installed in output.parents or output.exists():
        parser.error("--output must be a new directory outside the installed app")
    derived = Path(args.derived_data).expanduser().resolve() if args.derived_data else output / "DerivedData"
    if derived == installed or installed in derived.parents:
        parser.error("--derived-data cannot reference the installed app")
    output.mkdir(mode=0o700, parents=True)
    source_digest = digest_sources()
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain"]).stdout)
    command = ["xcodebuild", "-project", "ApplePlatformMCP.xcodeproj", "-scheme", "ApplePlatformMCP",
               "-configuration", "Release", "-destination", "generic/platform=macOS",
               "-derivedDataPath", str(derived), "-archivePath", str(output / "candidate.xcarchive"),
               "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=" + fingerprint, "DEVELOPMENT_TEAM=" + team,
               "APPLE_PLATFORM_MCP_BUILD_COMMIT=" + head, "archive"]
    # Build diagnostics stay in the private candidate directory.
    with (output / "build.log").open("w") as log:
        os.chmod(log.name, 0o600)
        result = subprocess.run(command, cwd=ROOT, env={**os.environ, "DEVELOPER_DIR": DEVELOPER},
                                stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print(json.dumps({"status": "archive_failed", "private_log": str(output / "build.log")}))
        return 1
    app = output / "candidate.xcarchive/Products/Applications/apple-platform-mcp.app"
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    details = run(["codesign", "-dv", "--verbose=4", str(app)]).stderr
    if f"TeamIdentifier={team}" not in details or "Authority=Developer ID Application:" not in details or "runtime" not in details:
        raise RuntimeError("candidate_signature_or_hardened_runtime_mismatch")
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (metadata.get("CFBundleIdentifier") != BUNDLE_ID
            or metadata.get("CFBundleExecutable") != "apple-platform-mcp"
            or metadata.get("ApplePlatformMCPBuildConfiguration") != "Release"):
        raise RuntimeError("candidate_bundle_metadata_mismatch")
    entitlement_result = run(["codesign", "-d", "--entitlements", ":-", str(app)])
    entitlements = plistlib.loads(entitlement_result.stdout.encode())
    if entitlements != {"com.apple.security.automation.apple-events": True, "com.apple.security.personal-information.calendars": True, "com.apple.security.personal-information.addressbook": True}:
        raise RuntimeError("candidate_entitlements_mismatch")
    if not metadata.get("NSContactsUsageDescription"):
        raise RuntimeError("candidate_contacts_usage_description_missing")
    if source_digest != digest_sources():
        raise RuntimeError("sources_changed_during_archive_rebuild_required")
    manifest = {"status": "signed_candidate_not_deployed", "app": str(app), "team_id": team,
                "identity_sha1": fingerprint, "source_sha256": source_digest, "git_head": head,
                "working_tree_dirty": dirty,
                "binary_sha256": hashlib.sha256((app / "Contents/MacOS/apple-platform-mcp").read_bytes()).hexdigest(),
                "notarized": False, "isolated_smoke_passed": False, "gateway_smoke_passed": False,
                "client_verified": False}
    (output / "candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"status": "failed", "error_type": type(error).__name__}))
        raise SystemExit(1)
