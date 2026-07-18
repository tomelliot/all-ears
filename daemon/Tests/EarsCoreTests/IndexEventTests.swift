import Foundation
import Testing

@testable import EarsCore

/// Fixtures mirror the exact JSON shapes documented in `docs/data-formats.md`.
/// `base` is 2026-07-17T10:30:00Z (1_784_284_200 s since epoch); other instants
/// are expressed as offsets from it for readability.
@Suite("IndexEvent")
struct IndexEventTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func decode(_ json: String) throws -> IndexEvent {
    try JSONDecoder().decode(IndexEvent.self, from: Data(json.utf8))
  }

  private func roundTrip(_ event: IndexEvent) throws -> IndexEvent {
    let data = try JSONEncoder().encode(event)
    return try JSONDecoder().decode(IndexEvent.self, from: data)
  }

  @Test("decodes a chunk event")
  func decodesChunk() throws {
    let json = """
      {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":480000}
      """
    let event = try decode(json)
    #expect(
      event
        == .chunk(
          start: base,
          end: base.advanced(by: 30),
          file: "chunks/2026-07-17T10-30-00Z.m4a",
          frames: 480_000
        ))
  }

  @Test(
    "decodes a vad event with fractional-second timestamps",
    arguments: [
      ("speech", VADState.speech),
      ("silence", VADState.silence),
    ])
  func decodesVAD(rawState: String, expected: VADState) throws {
    let json = """
      {"t":"vad","state":"\(rawState)","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
      """
    let event = try decode(json)
    #expect(
      event
        == .vad(
          state: expected,
          start: base.advanced(by: 2.14),
          end: base.advanced(by: 9.88)
        ))
  }

  @Test("decodes a gap event")
  func decodesGap() throws {
    let json = """
      {"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
      """
    let event = try decode(json)
    #expect(
      event
        == .gap(
          start: base.advanced(by: 60),
          end: base.advanced(by: 72),
          reason: "daemon_restart"
        ))
  }

  @Test("decodes an evict event")
  func decodesEvict() throws {
    let json = """
      {"t":"evict","file":"chunks/2026-07-17T08-30-00Z.m4a","start":"2026-07-17T08:30:00Z"}
      """
    let event = try decode(json)
    #expect(
      event
        == .evict(
          file: "chunks/2026-07-17T08-30-00Z.m4a",
          start: base.advanced(by: -7200)
        ))
  }

  @Test(
    "round-trips every event case through encode/decode",
    arguments: [
      IndexEvent.chunk(
        start: Instant(secondsSinceEpoch: 1_784_284_200),
        end: Instant(secondsSinceEpoch: 1_784_284_230), file: "chunks/a.m4a", frames: 480_000),
      IndexEvent.vad(
        state: .speech, start: Instant(secondsSinceEpoch: 1_784_284_202.14),
        end: Instant(secondsSinceEpoch: 1_784_284_209.88)),
      IndexEvent.gap(
        start: Instant(secondsSinceEpoch: 1_784_284_260),
        end: Instant(secondsSinceEpoch: 1_784_284_272), reason: "daemon_restart"),
      IndexEvent.evict(file: "chunks/old.m4a", start: Instant(secondsSinceEpoch: 1_784_277_000)),
    ])
  func roundTrips(event: IndexEvent) throws {
    #expect(try roundTrip(event) == event)
  }

  @Test("start accessor exposes the ordering instant for every case")
  func startAccessor() {
    #expect(
      IndexEvent.chunk(start: base, end: base.advanced(by: 30), file: "f", frames: 1).start == base)
    #expect(IndexEvent.vad(state: .speech, start: base, end: base.advanced(by: 1)).start == base)
    #expect(IndexEvent.gap(start: base, end: base.advanced(by: 1), reason: "r").start == base)
    #expect(IndexEvent.evict(file: "f", start: base).start == base)
  }

  @Test("throws on an unrecognised event tag")
  func unrecognisedTag() {
    let json = """
      {"t":"mystery","start":"2026-07-17T10:30:00Z"}
      """
    #expect(throws: (any Error).self) {
      try decode(json)
    }
  }

  @Test("throws when a required field is missing")
  func missingField() {
    let json = """
      {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/a.m4a"}
      """
    #expect(throws: (any Error).self) {
      try decode(json)
    }
  }

  @Test("throws on a malformed timestamp")
  func malformedTimestamp() {
    let json = """
      {"t":"evict","file":"chunks/a.m4a","start":"not-a-date"}
      """
    #expect(throws: (any Error).self) {
      try decode(json)
    }
  }
}
