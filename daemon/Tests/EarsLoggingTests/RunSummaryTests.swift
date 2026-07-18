import EarsCore
import Testing

@testable import EarsLogging

@Suite("RunSummary")
struct RunSummaryTests {
  @Test("builds a run.summary record with the caller's identity and fields")
  func buildsRecord() {
    let record = RunSummary.record(
      ts: Instant(secondsSinceEpoch: 42),
      tool: "transcribe",
      subsystem: "net.tomelliot.ears",
      category: "transcribe",
      pid: 5330,
      fields: [
        LogField("segments", 12),
        LogField("duration_ms", 8_140),
        LogField("output", "sessions/2026-07-17T10-30-00Z_standup/transcript.md"),
      ]
    )
    #expect(record.event == "run.summary")
    #expect(record.level == .info)
    #expect(record.tool == "transcribe")
    #expect(record.subsystem == "net.tomelliot.ears")
    #expect(record.category == "transcribe")
    #expect(record.pid == 5330)
    #expect(record.fields.map(\.key) == ["segments", "duration_ms", "output"])
    #expect(record.msg == nil)
  }

  @Test("defaults to no fields and no msg")
  func defaults() {
    let record = RunSummary.record(
      ts: Instant(secondsSinceEpoch: 0),
      tool: "cleanup",
      subsystem: "net.tomelliot.ears",
      category: "cleanup",
      pid: 1
    )
    #expect(record.fields.isEmpty)
    #expect(record.msg == nil)
  }

  @Test("allows overriding the level for a failed run's summary")
  func overridesLevel() {
    let record = RunSummary.record(
      ts: Instant(secondsSinceEpoch: 0),
      level: .error,
      tool: "transcribe",
      subsystem: "net.tomelliot.ears",
      category: "transcribe",
      pid: 1,
      msg: "aborted after 2 of 5 segments"
    )
    #expect(record.level == .error)
    #expect(record.msg == "aborted after 2 of 5 segments")
  }
}
