import Foundation

/// Non-sensitive identity for the source, configuration, and artifact serving
/// MCP requests. Commit values are accepted only in hexadecimal form so an
/// accidental path, username, token, or arbitrary environment value cannot be
/// surfaced through diagnostics.
public enum ApplePlatformMCPBuildProvenance {
  public static let serverVersion = "0.1.0"

  public static var buildCommit: String {
    guard
      let value = Bundle.main.object(forInfoDictionaryKey: "ApplePlatformMCPBuildCommit")
        as? String,
      value.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil
    else {
      return "unknown"
    }
    return value.lowercased()
  }

  public static var buildConfiguration: String {
    if let value = Bundle.main.object(forInfoDictionaryKey: "ApplePlatformMCPBuildConfiguration")
      as? String,
      ["Debug", "Release"].contains(value)
    {
      return value
    }
    #if DEBUG
      return "Debug"
    #else
      return "Release"
    #endif
  }
}
