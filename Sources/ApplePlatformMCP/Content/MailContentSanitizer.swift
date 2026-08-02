import Foundation

public enum MailContentSanitizer {
  public struct ParsedSource: Sendable {
    public let headers: [String: String]
    public let body: String

    public init(headers: [String: String], body: String) {
      self.headers = headers
      self.body = body
    }
  }

  public static func parseSource(_ source: String) -> ParsedSource {
    let separator: Range<String.Index>?
    if let range = source.range(of: "\r\n\r\n") {
      separator = range
    } else {
      separator = source.range(of: "\n\n")
    }

    guard let separator else {
      return ParsedSource(headers: parseHeaders(source), body: "")
    }

    let headerText = String(source[..<separator.lowerBound])
    let bodyStart = separator.upperBound
    return ParsedSource(
      headers: parseHeaders(headerText),
      body: String(source[bodyStart...])
    )
  }

  public static func body(
    from source: String,
    format: MailBodyFormat,
    maxBytes: Int
  ) -> MailBody {
    let parsed = parseSource(source)
    let extracted = extractBodies(from: parsed)
    let plainSource = extracted.plainText ?? extracted.html.map(stripMarkup) ?? parsed.body
    let htmlSource = extracted.html ?? parsed.body
    let plainText = truncate(stripMarkup(plainSource), to: maxBytes)
    let sanitizedHTML = truncate(sanitizeHTML(htmlSource), to: maxBytes)
    let plainOriginalByteCount = byteCount(plainSource)
    let htmlOriginalByteCount = byteCount(htmlSource)

    switch format {
    case .plainText:
      return MailBody(
        plainText: plainText,
        sanitizedHTML: nil,
        truncated: plainOriginalByteCount > maxBytes,
        originalByteCount: plainOriginalByteCount
      )
    case .sanitizedHTML:
      return MailBody(
        plainText: nil,
        sanitizedHTML: sanitizedHTML,
        truncated: htmlOriginalByteCount > maxBytes,
        originalByteCount: htmlOriginalByteCount
      )
    case .both:
      return MailBody(
        plainText: plainText,
        sanitizedHTML: extracted.html == nil ? nil : sanitizedHTML,
        truncated: plainOriginalByteCount > maxBytes || htmlOriginalByteCount > maxBytes,
        originalByteCount: max(plainOriginalByteCount, htmlOriginalByteCount)
      )
    }
  }

  public static func header(_ name: String, from source: String) -> String? {
    parseSource(source).headers[name.lowercased()]
  }

  private struct ExtractedBodies {
    var plainText: String?
    var html: String?
  }

  private static func extractBodies(
    from parsed: ParsedSource,
    depth: Int = 0
  ) -> ExtractedBodies {
    guard depth < 4 else {
      return ExtractedBodies(plainText: parsed.body, html: nil)
    }

    let rawContentType = parsed.headers["content-type"] ?? "text/plain"
    let contentType = rawContentType.lowercased()
    if contentType.hasPrefix("multipart/"),
      let boundary = parameter("boundary", in: rawContentType)
    {
      var extracted = ExtractedBodies(plainText: nil, html: nil)
      let marker = "--\(boundary)"
      for part in parsed.body.components(separatedBy: marker).dropFirst() {
        guard !part.hasPrefix("--") else { continue }
        let partSource = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partSource.isEmpty else { continue }
        let partBodies = extractBodies(from: parseSource(partSource), depth: depth + 1)
        extracted.plainText = extracted.plainText ?? partBodies.plainText
        extracted.html = extracted.html ?? partBodies.html
      }
      return extracted
    }

    let decodedBody = decodeTransferEncoding(parsed.body, headers: parsed.headers)
    if contentType.hasPrefix("text/html") {
      return ExtractedBodies(plainText: nil, html: decodedBody)
    }
    return ExtractedBodies(plainText: decodedBody, html: nil)
  }

  private static func parameter(_ name: String, in value: String) -> String? {
    for component in value.split(separator: ";").dropFirst() {
      let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
      guard
        pair.count == 2,
        pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
      else {
        continue
      }
      return pair[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return nil
  }

  private static func decodeTransferEncoding(
    _ value: String,
    headers: [String: String]
  ) -> String {
    switch headers["content-transfer-encoding"]?.lowercased() {
    case "base64":
      let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
      guard let data = Data(base64Encoded: compact) else { return value }
      return String(decoding: data, as: UTF8.self)
    case "quoted-printable":
      return decodeQuotedPrintable(value)
    default:
      return value
    }
  }

  private static func decodeQuotedPrintable(_ value: String) -> String {
    let normalized =
      value
      .replacingOccurrences(of: "=\r\n", with: "")
      .replacingOccurrences(of: "=\n", with: "")
    let bytes = Array(normalized.utf8)
    var decoded: [UInt8] = []
    var index = 0

    while index < bytes.count {
      if bytes[index] == 61, index + 2 < bytes.count,
        let high = hexValue(bytes[index + 1]),
        let low = hexValue(bytes[index + 2])
      {
        decoded.append(high * 16 + low)
        index += 3
      } else {
        decoded.append(bytes[index])
        index += 1
      }
    }

    return String(decoding: decoded, as: UTF8.self)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 55
    case 97...102: return byte - 87
    default: return nil
    }
  }

  private static func byteCount(_ value: String) -> Int {
    value.data(using: .utf8)?.count ?? 0
  }

  private static func parseHeaders(_ value: String) -> [String: String] {
    var headers: [String: String] = [:]
    var currentName: String?
    var currentValue = ""

    for line in value.components(separatedBy: .newlines) {
      if line.hasPrefix(" ") || line.hasPrefix("\t") {
        currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
        continue
      }

      if let currentName {
        headers[currentName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard let colon = line.firstIndex(of: ":") else {
        currentName = nil
        currentValue = ""
        continue
      }

      currentName = line[..<colon].lowercased()
      currentValue = String(line[line.index(after: colon)...])
    }

    if let currentName {
      headers[currentName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return headers
  }

  private static func truncate(_ value: String, to maxBytes: Int) -> String {
    guard maxBytes > 0, let data = value.data(using: .utf8), data.count > maxBytes else {
      return value
    }
    return String(decoding: data.prefix(maxBytes), as: UTF8.self)
  }

  private static func sanitizeHTML(_ value: String) -> String {
    var result = value
    let blockedElements = ["script", "style", "iframe", "object", "embed", "form"]
    for element in blockedElements {
      result = replacing(
        result,
        pattern: "(?is)<\(element)(?:\\s[^>]*)?>.*?</\(element)\\s*>",
        with: ""
      )
    }

    result = replacing(
      result, pattern: "(?is)\\s+on[a-z]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "")
    // Remove every URL-bearing attribute. Relative URLs can still resolve
    // against a client context, and javascript/data/file URLs are active
    // content even when they are not remote HTTP resources.
    result = replacing(
      result,
      pattern: "(?is)\\s+(?:src|href)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)",
      with: ""
    )
    return result
  }

  private static func stripMarkup(_ value: String) -> String {
    let withoutTags = replacing(value, pattern: "(?is)<[^>]+>", with: " ")
    return
      withoutTags
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replacing(
    _ value: String,
    pattern: String,
    with replacement: String
  ) -> String {
    value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
  }
}
