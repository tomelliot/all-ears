import Foundation
import Testing

@testable import EarsCore

/// Covers the per-command response `data` payload types: ``StatusData``,
/// ``SourcesListData``, ``SessionOpenData``, ``SessionListData``,
/// ``IngestOpenData``, and ``SessionSummary`` (the ISO-8601/`snake_case`
/// wire wrapper ``SessionListData`` carries sessions as — see that type's
/// doc comment for why it's distinct from ``SessionDescriptor``).
@Suite("StatusData")
struct StatusDataTests {
  @Test("decodes the spec's literal status example")
  func decodesSpecExample() throws {
    let json = """
      {"uptime_s":3600,"sources":[{"id":"mic","state":"capturing","codec":"aac"}]}
      """
    let data = try JSONDecoder().decode(StatusData.self, from: Data(json.utf8))
    #expect(data.uptimeSeconds == 3600)
    #expect(data.sources == [SourceStatus(id: "mic", state: .capturing, codec: "aac")])
  }

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let status = StatusData(
      uptimeSeconds: 42,
      sources: [
        SourceStatus(id: "mic", state: .capturing, codec: "aac"),
        SourceStatus(id: "app:us.zoom.xos", state: .paused, codec: "aac", bytesUsed: 2048),
      ])
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(StatusData.self, from: data)
    #expect(decoded == status)
  }
}

@Suite("SourcesListData")
struct SourcesListDataTests {
  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let list = SourcesListData(sources: [
      SourceStatus(id: "mic", state: .capturing, codec: "aac")
    ])
    let data = try JSONEncoder().encode(list)
    let decoded = try JSONDecoder().decode(SourcesListData.self, from: data)
    #expect(decoded == list)
  }
}

@Suite("SessionOpenData")
struct SessionOpenDataTests {
  @Test("decodes a bare session id")
  func decodesID() throws {
    let json = """
      {"id":"2026-07-17T10-30-00Z_standup"}
      """
    let data = try JSONDecoder().decode(SessionOpenData.self, from: Data(json.utf8))
    #expect(data == SessionOpenData(id: "2026-07-17T10-30-00Z_standup"))
  }
}

@Suite("IngestOpenData")
struct IngestOpenDataTests {
  @Test("decodes the spec's literal stream_id example")
  func decodesSpecExample() throws {
    let json = """
      {"stream_id":"s7"}
      """
    let data = try JSONDecoder().decode(IngestOpenData.self, from: Data(json.utf8))
    #expect(data == IngestOpenData(streamID: "s7"))
  }
}

@Suite("SessionSummary")
struct SessionSummaryTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  @Test("encodes with ISO-8601 timestamps and snake_case trigger_detail")
  func encodesWireShape() throws {
    let summary = SessionSummary(
      SessionDescriptor(
        schema: 1,
        id: "2026-07-17T10-30-00Z_standup",
        slug: "standup",
        sources: ["mic", "app:us.zoom.xos"],
        start: base,
        end: base.advanced(by: 1920),
        state: .closed,
        trigger: .appSignal,
        triggerDetail: "us.zoom.xos",
        vocab: "vocab/2026-07-17T10-30-00Z_standup.txt"
      ))
    let data = try JSONEncoder().encode(summary)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["start"] as? String == "2026-07-17T10:30:00.000Z")
    #expect(object["end"] as? String == "2026-07-17T11:02:00.000Z")
    #expect(object["trigger_detail"] as? String == "us.zoom.xos")
    #expect(object["triggerDetail"] == nil)
  }

  @Test("round-trips through encode/decode, including a still-open session")
  func roundTripsOpenSession() throws {
    let summary = SessionSummary(
      SessionDescriptor(
        schema: 1,
        id: "2026-07-17T10-30-00Z_standup",
        slug: "standup",
        sources: ["mic"],
        start: base,
        end: nil,
        state: .open,
        trigger: .manual
      ))
    let data = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(SessionSummary.self, from: data)
    #expect(decoded == summary)
    #expect(decoded.descriptor == summary.descriptor)
  }
}

@Suite("SessionListData")
struct SessionListDataTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let list = SessionListData(sessions: [
      SessionSummary(
        SessionDescriptor(
          schema: 1, id: "2026-07-17T10-30-00Z_standup", slug: "standup", sources: ["mic"],
          start: base, state: .open, trigger: .manual))
    ])
    let data = try JSONEncoder().encode(list)
    let decoded = try JSONDecoder().decode(SessionListData.self, from: data)
    #expect(decoded == list)
  }
}
