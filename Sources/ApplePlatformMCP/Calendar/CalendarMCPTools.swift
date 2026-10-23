import Foundation
import MCP

public enum CalendarMCPTools {
  private static func object(_ fields: [String: Value], required: [String] = []) -> Value {
    .object([
      "type": .string("object"), "properties": .object(fields),
      "additionalProperties": .bool(false), "required": .array(required.map(Value.string)),
    ])
  }
  private static let string: Value = .object(["type": .string("string")])
  private static let time: Value = object(
    [
      "start": string, "end": string, "time_zone": string,
      "all_day": .object(["type": .string("boolean")]),
    ], required: ["start", "end", "time_zone"])
  public static let tools: [Tool] = [
    Tool(
      name: "calendar_list_calendars",
      description:
        "List EventKit calendars with independent Calendar write-policy flags. Full Access required; content is untrusted.",
      inputSchema: object([:]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true)),
    Tool(
      name: "calendar_search_events",
      description:
        "Search event titles in an explicit time window (maximum 366 days). Omitting calendar_ids searches all readable calendars. Recurring occurrences are separate. Inspect truncated; no pagination.",
      inputSchema: object(
        [
          "time": time, "calendar_ids": .object(["type": .string("array"), "items": string]),
          "query": string,
          "limit": .object(["type": .string("integer")]),
        ], required: ["time"]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true)),
    Tool(
      name: "calendar_get_event",
      description:
        "Read the exact event occurrence returned by Calendar search; stale or ambiguous references are refused.",
      inputSchema: object(["event_id": string], required: ["event_id"]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true)),
    Tool(
      name: "calendar_check_conflicts",
      description:
        "Check half-open time overlap across all readable calendars. Free/cancelled events are excluded. This is a snapshot, not a reservation. Inspect completeness.",
      inputSchema: object(["time": time], required: ["time"]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true)),
    Tool(
      name: "calendar_create_event",
      description:
        "Create one event in an explicit policy-allowed writable calendar. Overlap or incomplete conflict checks produce warnings, not a block. No attendees, alarms or recurrence. Durable idempotency_key is required; never retry an unknown outcome with a new key.",
      inputSchema: object(
        [
          "calendar_id": string, "title": string, "time": time, "location": string, "notes": string,
          "idempotency_key": string,
        ],
        required: ["calendar_id", "title", "time", "idempotency_key"]),
      annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)),
    Tool(
      name: "calendar_get_creation_outcome",
      description:
        "Read a durable Calendar create outcome without creating an event. Unknown outcomes remain blocked; do not retry with a new key.",
      inputSchema: object(["idempotency_key": string], required: ["idempotency_key"]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)),
  ]
  struct Response {
    let data: Value
    let truncated: Bool
  }
  static func call(_ name: String, arguments: [String: Value]?, service: CalendarToolService)
    async throws -> Response
  {
    let args = arguments ?? [:]
    let allowed: Set<String>
    switch name {
    case "calendar_list_calendars": allowed = []
    case "calendar_search_events": allowed = ["time", "calendar_ids", "query", "limit"]
    case "calendar_get_event": allowed = ["event_id"]
    case "calendar_check_conflicts": allowed = ["time"]
    case "calendar_create_event":
      allowed = ["calendar_id", "title", "time", "location", "notes", "idempotency_key"]
    case "calendar_get_creation_outcome": allowed = ["idempotency_key"]
    default: throw CalendarError("calendarInvalidInput")
    }
    guard Set(args.keys).isSubset(of: allowed) else { throw CalendarError("calendarInvalidInput") }
    func text(_ key: String) throws -> String {
      guard let value = args[key]?.stringValue else { throw CalendarError("calendarInvalidInput") }
      return value
    }
    func optionalText(_ key: String) throws -> String? { args[key] == nil ? nil : try text(key) }
    func interval() throws -> CalendarTimeRange {
      guard let value = args["time"]?.objectValue,
        Set(value.keys).isSubset(of: ["start", "end", "time_zone", "all_day"]),
        let start = value["start"]?.stringValue, let end = value["end"]?.stringValue,
        let zone = value["time_zone"]?.stringValue
      else { throw CalendarError("calendarInvalidInput") }
      var allDay = false
      if let value = value["all_day"] {
        guard let boolean = value.boolValue else { throw CalendarError("calendarInvalidInput") }
        allDay = boolean
      }
      return .init(start: start, end: end, timeZone: zone, allDay: allDay)
    }
    switch name {
    case "calendar_list_calendars":
      return .init(data: try Value(try await service.listCalendars()), truncated: false)
    case "calendar_get_event":
      let result = try await service.getEvent(id: text("event_id"))
      return .init(data: try Value(result), truncated: result.truncated)
    case "calendar_search_events":
      var ids: [String]?
      if let value = args["calendar_ids"] {
        guard let array = value.arrayValue, !array.isEmpty, array.count <= 1000 else {
          throw CalendarError("calendarInvalidInput")
        }
        ids = try array.map {
          guard let id = $0.stringValue else { throw CalendarError("calendarInvalidInput") }
          return id
        }
      }
      var limit: Int?
      if let value = args["limit"] {
        guard case .int(let integer) = value else { throw CalendarError("calendarInvalidInput") }
        limit = integer
      }
      let result = try await service.search(
        time: interval(), calendarIDs: ids, query: optionalText("query") ?? "", limit: limit)
      return .init(data: try Value(result), truncated: result.truncated)
    case "calendar_check_conflicts":
      let result = try await service.checkConflicts(time: interval())
      return .init(data: try Value(result), truncated: result.truncated)
    case "calendar_create_event":
      let request = CalendarCreateRequest(
        calendarID: try text("calendar_id"), title: try text("title"), time: try interval(),
        location: try optionalText("location"), notes: try optionalText("notes"))
      return .init(
        data: try Value(try await service.create(request, key: text("idempotency_key"))),
        truncated: false)
    default:
      return .init(
        data: try Value(try await service.creationOutcome(key: text("idempotency_key"))),
        truncated: false)
    }
  }
}
