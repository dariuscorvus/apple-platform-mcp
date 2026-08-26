import Darwin
import Dispatch
import Foundation

#if SWIFT_PACKAGE
  import ApplePlatformMCPKit
#endif

@main
struct ApplePlatformMCPMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch try ApplePlatformMCPCommand.parse(arguments) {
      case .doctor(let requestAutomation):
        let report =
          requestAutomation
          ? ApplePlatformMCPDoctor.requestAutomation()
          : ApplePlatformMCPDoctor.inspect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(Int32(report.exitCode))

      case .doctorReminders:
        let report = await ApplePlatformMCPDoctor.requestReminders()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(Int32(report.exitCode))

      case .serve(transport: .stdio, configurationURL: let configurationURL):
        let configuration = try MailServerConfiguration.load(
          from: configurationURL ?? MailServerConfiguration.defaultURL
        )
        let repository = try ScriptingBridgeMailRepository()
        let service = MailToolService(repository: repository, policy: configuration.policy)
        let reminderRepository = EventKitReminderRepository()
        let reminderService = ReminderToolService(
          repository: reminderRepository,
          maxResults: configuration.maxResults,
          policy: configuration.reminderPolicy
        )
        try await ApplePlatformMCPServer(
          service: service,
          reminderService: reminderService,
          configuration: configuration
        ).run()

      case .serve(
        transport: .streamableHTTP(let host, let port),
        configurationURL: let configurationURL
      ):
        let configuration = try MailServerConfiguration.load(
          from: configurationURL ?? MailServerConfiguration.defaultURL
        )
        let repository = try ScriptingBridgeMailRepository()
        let service = MailToolService(repository: repository, policy: configuration.policy)
        let reminderRepository = EventKitReminderRepository()
        let reminderService = ReminderToolService(
          repository: reminderRepository,
          maxResults: configuration.maxResults,
          policy: configuration.reminderPolicy
        )
        let server = await ApplePlatformMCPServer(
          service: service,
          reminderService: reminderService,
          configuration: configuration
        ).makeServer()
        let runtime = ApplePlatformMCPStreamableHTTPRuntime(
          server: server,
          readinessProbe: {
            let diagnostics = MailAutomationDiagnostics.inspect()
            return diagnostics.mailAppRunning && diagnostics.permission == .allowed
          }
        )
        try await runtime.start()
        let listener = ApplePlatformMCPHTTPServer(
          host: host,
          port: port,
          router: runtime.router
        )
        do {
          let boundPort = try await listener.start()
          let message = "apple-platform-mcp listening on http://\(host):\(boundPort)/mcp\n"
          FileHandle.standardError.write(Data(message.utf8))
          await waitForShutdown(of: listener)
        } catch {
          await listener.stop()
          await runtime.stop()
          throw error
        }
        await runtime.stop()
      }
    } catch {
      let message = "apple-platform-mcp failed to start: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func waitForShutdown(of listener: ApplePlatformMCPHTTPServer) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await listener.waitUntilClosed()
      }
      group.addTask {
        for await _ in terminationSignals() {
          break
        }
      }
      await group.next()
      await listener.stop()
      group.cancelAll()
    }
  }

  private static func terminationSignals() -> AsyncStream<Int32> {
    AsyncStream { continuation in
      signal(SIGINT, SIG_IGN)
      signal(SIGTERM, SIG_IGN)

      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM)
      interrupt.setEventHandler { continuation.yield(SIGINT) }
      terminate.setEventHandler { continuation.yield(SIGTERM) }
      continuation.onTermination = { _ in
        interrupt.cancel()
        terminate.cancel()
      }
      interrupt.resume()
      terminate.resume()
    }
  }
}
