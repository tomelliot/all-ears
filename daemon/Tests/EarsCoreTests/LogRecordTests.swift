import Testing

@testable import EarsCore

@Suite("LogRecord")
struct LogRecordTests {
  @Test("defaults msg to nil and fields to empty")
  func defaults() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: "source.opened"
    )
    #expect(record.msg == nil)
    #expect(record.fields.isEmpty)
  }

  @Test("stores baseline fields and ordered context fields")
  func storesFields() {
    let record = LogRecord(
      ts: Instant(secondsSinceEpoch: 1_784_536_200.012),
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
    #expect(record.tool == "earsd")
    #expect(record.subsystem == "net.tomelliot.ears")
    #expect(record.category == "earsd")
    #expect(record.pid == 4120)
    #expect(record.event == "device.lost")
    #expect(record.msg == "mic device lost, reopening")
    #expect(record.fields.map(\.key) == ["source", "reason", "action"])
  }

  @Test("equatable by value, including field order")
  func equatable() {
    let base = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written",
      fields: [LogField("frames", 480_000), LogField("source", "mic")]
    )
    let reordered = LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      event: "chunk.written",
      fields: [LogField("source", "mic"), LogField("frames", 480_000)]
    )
    #expect(base != reordered)
    #expect(
      base
        == LogRecord(
          ts: Instant(secondsSinceEpoch: 0),
          level: .info,
          tool: "earsd",
          subsystem: "net.tomelliot.ears",
          category: "earsd",
          pid: 1,
          event: "chunk.written",
          fields: [LogField("frames", 480_000), LogField("source", "mic")]
        )
    )
  }
}
