import Foundation
import Testing

@testable import EarsCore

/// Covers ``SourceStatus``: the per-source payload shared by `status` and
/// `sources.list` responses.
///
/// **Wire-shape decision:** `docs/specs/capture-daemon.md` gives one literal
/// example field set — `id`/`state`/`codec` — but `status`'s one-line spec
/// also promises "buffer occupancy". This adds `oldest_chunk_start`,
/// `newest_chunk_end` (both ISO-8601, via the same rendering
/// ``IndexTimestampCodec`` uses for `index.jsonl`), and `bytes_used` (bytes)
/// for that. All three are optional/defaulted on decode so the spec's
/// original minimal example still decodes cleanly.
@Suite("SourceStatus")
struct SourceStatusTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  @Test("decodes the spec's literal minimal example, defaulting occupancy fields")
  func decodesSpecExample() throws {
    let json = """
      {"id":"mic","state":"capturing","codec":"aac"}
      """
    let status = try JSONDecoder().decode(SourceStatus.self, from: Data(json.utf8))
    #expect(status.id == "mic")
    #expect(status.state == .capturing)
    #expect(status.codec == "aac")
    #expect(status.oldestChunkStart == nil)
    #expect(status.newestChunkEnd == nil)
    #expect(status.bytesUsed == 0)
  }

  @Test("decodes a fully-populated status with occupancy fields")
  func decodesFull() throws {
    let json = """
      {
        "id":"mic","state":"capturing","codec":"aac",
        "oldest_chunk_start":"2026-07-17T08:30:00Z",
        "newest_chunk_end":"2026-07-17T10:30:00Z",
        "bytes_used":12582912
      }
      """
    let status = try JSONDecoder().decode(SourceStatus.self, from: Data(json.utf8))
    #expect(status.oldestChunkStart == base.advanced(by: -7200))
    #expect(status.newestChunkEnd == base)
    #expect(status.bytesUsed == 12_582_912)
  }

  @Test(
    "round-trips every runtime state through encode/decode",
    arguments: [
      SourceRuntimeState.capturing, .paused, .disabled, .error,
    ])
  func roundTripsState(state: SourceRuntimeState) throws {
    let status = SourceStatus(
      id: "mic", state: state, codec: "aac",
      oldestChunkStart: base, newestChunkEnd: base.advanced(by: 30), bytesUsed: 1024)
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(SourceStatus.self, from: data)
    #expect(decoded == status)
  }

  @Test("throws on a malformed occupancy timestamp")
  func throwsOnMalformedTimestamp() {
    let json = """
      {"id":"mic","state":"capturing","codec":"aac","oldest_chunk_start":"not-a-date"}
      """
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SourceStatus.self, from: Data(json.utf8))
    }
  }
}
