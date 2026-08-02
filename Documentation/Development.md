# Development

## Generate the Xcode project

```sh
xcodegen generate --spec project.yml
```

`project.yml` is the source of truth. The generated `.xcodeproj`, shared scheme, and `Package.resolved` remain checked in so the project opens directly in Xcode.

The product is a background app bundle because Apple Events permission and signing are bundle-scoped. MCP clients invoke the embedded executable directly.

## Regenerate the Mail bridge

The generated bridge is tied to the Mail.app scripting definition installed on the machine. Regenerate all three checked-in artifacts together:

```sh
Scripts/generate-mail-bridge.sh
```

The script runs `sdef` and `sdp` against `/System/Applications/Mail.app`. Review the generated diff before building.

## Format

```sh
xcrun swift-format format --in-place --recursive Sources Tests
xcrun swift-format lint --recursive Sources Tests
```

## Build and test

Use a fresh derived-data and Swift package cache directory for reproducible local checks:

```sh
xcodebuild \
  -project ApplePlatformMCP.xcodeproj \
  -scheme ApplePlatformMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/apple-platform-mcp-derived \
  -clonedSourcePackagesDirPath /tmp/apple-platform-mcp-packages \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Run the same command with `test` instead of `build` for the unit and contract test target.

## Diagnose the host

```sh
apple-platform-mcp.app/Contents/MacOS/apple-platform-mcp doctor
```

The output contains only platform, signing, policy, configuration, and Mail/TCC status. It never lists accounts or reads message data.

## Configuration

The optional file is:

```text
~/.config/apple-platform-mcp/config.json
```

The bootstrap uses JSON so the local server has no YAML parser dependency. The file contains policy references and limits only; Mail.app remains the owner of account credentials.

An absent file means read-only defaults. Invalid configuration fails closed. Write modes are not accepted.
