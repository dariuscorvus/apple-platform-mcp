import ApplePlatformMCPKit
import Darwin
import Foundation

@main
struct ApplePlatformMCPMain {
  static func main() async {
    if CommandLine.arguments.dropFirst().first == "doctor" {
      let report = ApplePlatformMCPDoctor.inspect()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(report) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
      }
      exit(Int32(report.exitCode))
    }

    do {
      let configuration = try MailServerConfiguration.load()
      let repository = try ScriptingBridgeMailRepository()
      let service = MailToolService(repository: repository, policy: configuration.policy)
      try await ApplePlatformMCPServer(
        service: service,
        configuration: configuration
      ).run()
    } catch {
      let message = "apple-platform-mcp failed to start: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EXIT_FAILURE)
    }
  }
}
