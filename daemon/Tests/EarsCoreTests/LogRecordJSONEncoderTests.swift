import Foundation
import Testing

@testable import EarsCore

private func instant(fromISO iso: String) -> Instant {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let date = formatter.date(from: iso) else {
    fatalError("bad ISO fixture: \(iso)")
  }
  return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
}

@Suite("LogRecordJSONEncoder")
struct LogRecordJSONEncoderTests {
  @Test("matches docs/logging.md's source.opened example field-for-field")
  func sourceOpenedExample() {
    let record = LogRecord(
      ts: instant(fromISO: "2026-07-17T10:30:00.012Z"),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: "source.opened",
      fields: [
        LogField("source", "mic"),
        LogField("sample_rate", 16_000),
        LogField("codec", "aac"),
      ]
    )
    let expected =
      "{\"ts\":\"2026-07-17T10:30:00.012Z\",\"level\":\"info\",\"tool\":\"earsd\","
      + "\"subsystem\":\"net.tomelliot.ears\",\"category\":\"earsd\",\"pid\":4120,"
      + "\"event\":\"source.opened\",\"source\":\"mic\",\"sample_rate\":16000,\"codec\":\"aac\"}"
    #expect(LogRecordJSONEncoder.encode(record) == expected)
  }

  @Test("places msg last, after context fields")
  func msgIsLast() {
    let record = LogRecord(
      ts: instant(fromISO: "2026-07-17T10:31:12.881Z"),
      level: .error,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: "device.lost",
      msg: "mic device lost, reopening",
      fields: [
        LogField("source", "mic"),
        LogField("reason", "default input changed"),
        LogField("action", "reopening"),
      ]
    )
    let expected =
      "{\"ts\":\"2026-07-17T10:31:12.881Z\",\"level\":\"error\",\"tool\":\"earsd\","
      + "\"subsystem\":\"net.tomelliot.ears\",\"category\":\"earsd\",\"pid\":4120,"
      + "\"event\":\"device.lost\",\"source\":\"mic\",\"reason\":\"default input changed\","
      + "\"action\":\"reopening\",\"msg\":\"mic device lost, reopening\"}"
    #expect(LogRecordJSONEncoder.encode(record) == expected)
  }

  @Test("omits msg entirely when nil")
  func msgOmittedWhenNil() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written"
    )
    #expect(!LogRecordJSONEncoder.encode(record).contains("\"msg\""))
  }

  @Test("encodes duration_ms as an int and rtf as a double")
  func stageEndExample() {
    let record = LogRecord(
      ts: instant(fromISO: "2026-07-17T11:02:14.220Z"),
      level: .info,
      tool: "transcribe",
      subsystem: "net.tomelliot.ears",
      category: "transcribe",
      pid: 5330,
      event: "stage.end",
      fields: [
        LogField("session", "...standup"),
        LogField("span_id", "a1"),
        LogField("stage", "asr"),
        LogField("duration_ms", 8_140),
        LogField("rtf", 0.11),
      ]
    )
    let json = LogRecordJSONEncoder.encode(record)
    #expect(json.contains("\"duration_ms\":8140"))
    #expect(json.contains("\"rtf\":0.11"))
  }

  @Test("encodes bool fields as bare true/false")
  func boolField() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .debug,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "config.loaded",
      fields: [LogField("oslog_enabled", true)]
    )
    #expect(LogRecordJSONEncoder.encode(record).contains("\"oslog_enabled\":true"))
  }

  @Test("escapes quotes, backslashes, and control characters in strings")
  func escaping() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .error,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "device.lost",
      fields: [LogField("detail", "line1\nline2 \"quoted\" back\\slash")]
    )
    let json = LogRecordJSONEncoder.encode(record)
    #expect(json.contains("\"detail\":\"line1\\nline2 \\\"quoted\\\" back\\\\slash\""))
  }

  @Test("produces a single line with no embedded newline")
  func singleLine() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written",
      fields: [LogField("detail", "a\nb")]
    )
    #expect(!LogRecordJSONEncoder.encode(record).contains("\n"))
  }
}
