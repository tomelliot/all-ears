import Foundation
import Testing

@testable import EarsCore

@Suite("LogLevel")
struct LogLevelTests {
  @Test(
    "raw value round-trips through the doc's four levels",
    arguments: [
      (LogLevel.debug, "debug"),
      (LogLevel.info, "info"),
      (LogLevel.notice, "notice"),
      (LogLevel.error, "error"),
    ]
  )
  func rawValueRoundTrips(level: LogLevel, raw: String) {
    #expect(level.rawValue == raw)
    #expect(LogLevel(rawValue: raw) == level)
  }

  @Test("is Codable via its raw string")
  func codable() throws {
    let encoded = try JSONEncoder().encode(LogLevel.notice)
    #expect(String(data: encoded, encoding: .utf8) == "\"notice\"")
    let decoded = try JSONDecoder().decode(LogLevel.self, from: encoded)
    #expect(decoded == .notice)
  }

  @Test(
    "is severity-ordered debug < info < notice < error, per docs/logging.md's table order",
    arguments: [
      (LogLevel.debug, LogLevel.info),
      (LogLevel.info, LogLevel.notice),
      (LogLevel.notice, LogLevel.error),
      (LogLevel.debug, LogLevel.error),
    ]
  )
  func severityOrdering(lower: LogLevel, higher: LogLevel) {
    #expect(lower < higher)
    #expect(higher > lower)
    #expect(!(higher < lower))
  }

  @Test("a level is neither less than nor greater than itself, and is at least itself")
  func reflexiveOrdering() {
    for level in LogLevel.allCases {
      #expect(!(level < level))
      #expect(level >= level)
      #expect(level <= level)
    }
  }
}
