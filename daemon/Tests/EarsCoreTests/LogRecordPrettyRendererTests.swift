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

@Suite("LogRecordPrettyRenderer")
struct LogRecordPrettyRendererTests {
  @Test("includes ts, level, tool, and event")
  func includesCoreFields() {
    let record = LogRecord(
      ts: instant(fromISO: "2026-07-17T10:30:00.012Z"),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: "source.opened"
    )
    let rendered = LogRecordPrettyRenderer.render(record)
    #expect(rendered.contains("2026-07-17T10:30:00.012Z"))
    #expect(rendered.contains("INFO"))
    #expect(rendered.contains("earsd"))
    #expect(rendered.contains("source.opened"))
  }

  @Test("renders context fields as key=value")
  func rendersFields() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: "source.opened",
      fields: [LogField("source", "mic"), LogField("sample_rate", 16_000)]
    )
    let rendered = LogRecordPrettyRenderer.render(record)
    #expect(rendered.contains("source=mic"))
    #expect(rendered.contains("sample_rate=16000"))
  }

  @Test("appends msg when present, omits it when nil")
  func msgPresence() {
    let withMsg = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .error,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "device.lost",
      msg: "mic device lost, reopening"
    )
    #expect(LogRecordPrettyRenderer.render(withMsg).contains("mic device lost, reopening"))

    let withoutMsg = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written"
    )
    #expect(!LogRecordPrettyRenderer.render(withoutMsg).contains("nil"))
  }

  @Test("is a single line")
  func singleLine() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written",
      fields: [LogField("file", "chunks/2026-07-17T10-30-00Z.m4a")]
    )
    #expect(!LogRecordPrettyRenderer.render(record).contains("\n"))
  }
}
