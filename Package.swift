// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ApplePlatformMCP",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ApplePlatformMCPKit", targets: ["ApplePlatformMCPKit"]),
    .executable(name: "apple-platform-mcp", targets: ["apple-platform-mcp"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      exact: "0.12.1"
    ),
    .package(
      url: "https://github.com/apple/swift-nio.git",
      exact: "2.101.3"
    ),
    .package(
      url: "https://github.com/apple/swift-log.git",
      exact: "1.14.0"
    ),
  ],
  targets: [
    .target(
      name: "MailScriptingBridge",
      path: "Sources/MailScriptingBridge",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("ScriptingBridge"),
      ]
    ),
    .target(
      name: "ApplePlatformMCPKit",
      dependencies: [
        "MailScriptingBridge",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "Sources/ApplePlatformMCP",
      linkerSettings: [
        .linkedFramework("CoreServices"),
        .linkedFramework("Security"),
        .linkedFramework("ScriptingBridge"),
      ]
    ),
    .executableTarget(
      name: "apple-platform-mcp",
      dependencies: [
        "ApplePlatformMCPKit",
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: "Sources/ApplePlatformMCPServer"
    ),
    .testTarget(
      name: "ApplePlatformMCPTests",
      dependencies: [
        "ApplePlatformMCPKit",
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: "Tests/ApplePlatformMCPTests"
    ),
  ]
)
