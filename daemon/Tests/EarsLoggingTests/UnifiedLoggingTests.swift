import EarsCore
import Testing

@testable import EarsLogging

/// A fake ``UnifiedLogging`` conformance: os.Logger itself can't be
/// meaningfully asserted on in a unit test (there's no readback API), so per
/// `docs/engineering-practices.md`'s tier-2 guidance the boundary is kept
/// thin and tests exercise the protocol via this recorder instead of the
/// real `OSLogUnifiedLogging`.
final class RecordingUnifiedLogging: UnifiedLogging, @unchecked Sendable {
  private(set) var recorded: [LogRecord] = []

  func log(_ record: LogRecord) {
    recorded.append(record)
  }
}

@Suite("UnifiedLogging")
struct UnifiedLoggingTests {
  private func record(level: LogLevel, event: String) -> LogRecord {
    LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: level,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: event
    )
  }

  @Test("a fake conformance records every call it receives")
  func recorderCapturesCalls() {
    let recorder = RecordingUnifiedLogging()
    let record = record(level: .info, event: "source.opened")
    recorder.log(record)
    #expect(recorder.recorded == [record])
  }

  @Test("OSLogUnifiedLogging maps every LogLevel to an OSLogType without crashing")
  func realConformanceHandlesEveryLevel() {
    let mirror = OSLogUnifiedLogging(subsystem: "net.tomelliot.ears", category: "earsd")
    for level in LogLevel.allCases {
      mirror.log(record(level: level, event: "smoke"))
    }
  }

  @Test("NoOpUnifiedLogging discards every record for [log].oslog = false")
  func noOpDiscardsRecords() {
    let mirror = NoOpUnifiedLogging()
    for level in LogLevel.allCases {
      mirror.log(record(level: level, event: "smoke"))
    }
  }
}
