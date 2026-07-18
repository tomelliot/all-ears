import Foundation
import Testing

@testable import EarsCore

/// Covers ``EarsEvent``: the pub/sub live-feed events (`vad`, `session`,
/// `segment`), matching `docs/specs/capture-daemon.md`'s literal
/// event-stream examples, discriminated on the wire by `"ev"` (mirroring
/// ``IndexEvent``'s `"t"`-tag pattern and ``ControlRequest``'s `"cmd"`-tag
/// pattern).
@Suite("EarsEvent")
struct EarsEventTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func decode(_ json: String) throws -> EarsEvent {
    try JSONDecoder().decode(EarsEvent.self, from: Data(json.utf8))
  }

  private func roundTrip(_ event: EarsEvent) throws -> EarsEvent {
    let data = try JSONEncoder().encode(event)
    return try JSONDecoder().decode(EarsEvent.self, from: data)
  }

  @Test("decodes the spec's literal vad event")
  func decodesVAD() throws {
    let json = """
      {"ev":"vad","source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}
      """
    #expect(
      try decode(json) == .vad(source: "mic", state: .speech, t: base.advanced(by: 2.14)))
  }

  @Test("decodes the spec's literal session event")
  func decodesSession() throws {
    let json = """
      {"ev":"session","id":"2026-07-17T10-30-00Z_standup","state":"open"}
      """
    #expect(
      try decode(json) == .session(id: "2026-07-17T10-30-00Z_standup", state: .open))
  }

  @Test("decodes the spec's literal segment event")
  func decodesSegment() throws {
    let json = """
      {"ev":"segment","session":"2026-07-17T10-30-00Z_standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}
      """
    #expect(
      try decode(json)
        == .segment(
          session: "2026-07-17T10-30-00Z_standup", speaker: "You", start: 604.1, end: 611.9,
          text: "..."))
  }

  @Test(
    "round-trips every case through encode/decode",
    arguments: [
      EarsEvent.vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1_784_284_202.14)),
      EarsEvent.vad(
        source: "app:us.zoom.xos", state: .silence,
        t: Instant(secondsSinceEpoch: 1_784_284_209.88)),
      EarsEvent.session(id: "2026-07-17T10-30-00Z_standup", state: .open),
      EarsEvent.session(id: "2026-07-17T10-30-00Z_standup", state: .closed),
      EarsEvent.segment(
        session: "2026-07-17T10-30-00Z_standup", speaker: "You", start: 604.1, end: 611.9,
        text: "Nothing from me, the deploy went out last night."),
    ])
  func roundTrips(event: EarsEvent) throws {
    #expect(try roundTrip(event) == event)
  }

  @Test("throws on an unrecognised ev tag")
  func unrecognisedTag() {
    #expect(throws: (any Error).self) {
      try decode("{\"ev\":\"mystery\"}")
    }
  }
}
