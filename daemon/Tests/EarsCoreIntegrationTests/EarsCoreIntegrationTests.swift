import Foundation
import Testing

@testable import EarsCore

/// A `sources/<id>/` fixture directory on disk, shaped exactly like
/// `docs/data-formats.md` describes (`meta.toml`, `chunks/`, `index.jsonl`).
/// Chunk files are zero-byte placeholders — Phase 0 does no codec work, so
/// only the paths need to exist, not real audio.
///
/// This is the "fixture ring buffer" the roadmap's Phase 0 exit criterion
/// names: a real directory on disk that `EarsCore`'s pure index types read
/// back through actual file I/O, rather than an in-memory `[IndexEvent]`
/// literal (which is what `IndexLogTests`/`RangeReconstructionTests`/
/// `RingBufferEvictionTests` already exercise at tier 0).
private final class SourceFixture {
  let sourceDirectory: URL
  let indexFileURL: URL
  private let rootDirectory: URL

  init(indexJSONL: String, chunkFiles: [String]) {
    rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("EarsCoreIntegrationTests-\(UUID().uuidString)", isDirectory: true)
    sourceDirectory = rootDirectory.appendingPathComponent("sources/mic", isDirectory: true)
    let chunksDirectory = sourceDirectory.appendingPathComponent("chunks", isDirectory: true)
    try? FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

    for file in chunkFiles {
      FileManager.default.createFile(
        atPath: chunksDirectory.appendingPathComponent(file).path, contents: nil)
    }

    let metaTOML = """
      schema = 1
      id = "mic"
      class = "mic"
      label = "Mic"
      native_sample_rate = 48000
      asr_sample_rate = 16000
      channels = 1
      codec = "aac"
      time_cap_seconds = 7200
      created = "2026-07-17T08:00:00Z"
      """
    try? metaTOML.write(
      to: sourceDirectory.appendingPathComponent("meta.toml"), atomically: true, encoding: .utf8)

    indexFileURL = sourceDirectory.appendingPathComponent("index.jsonl")
    try? indexJSONL.write(to: indexFileURL, atomically: true, encoding: .utf8)
  }

  deinit {
    try? FileManager.default.removeItem(at: rootDirectory)
  }
}

/// Tier-1 integration tests, per `docs/engineering-practices.md`'s layered
/// test strategy: `EarsCore`'s already-unit-tested index logic (``IndexLog``,
/// ``RangeReconstructor``, ``RingBufferEviction``), read and exercised
/// end-to-end against a fixture ring buffer directory on disk. This is the
/// roadmap's Phase 0 exit criterion — "a fixture ring buffer can be created
/// and read by EarsCore" — made literal and green.
///
/// The value here is proving the pieces compose against something shaped
/// like a real fixture directory; per-case edge behaviour (clipping at
/// boundaries, malformed lines, cutoff-exact retention, ...) is already
/// covered at tier 0 in `IndexLogTests`/`RangeReconstructionTests`/
/// `RingBufferEvictionTests` and is deliberately not re-tested here.
@Suite("Fixture ring buffer")
struct FixtureRingBufferTests {
  /// 2026-07-17T10:30:00Z, matching the epoch base the tier-0 index tests
  /// use, so timestamps in this fixture read the same way.
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func range(_ startOffset: Double, _ endOffset: Double) -> TimeRange {
    TimeRange(start: base.advanced(by: startOffset), end: base.advanced(by: endOffset))
  }

  /// A realistic multi-event `index.jsonl`: four chunks (with a capture gap
  /// between the second and third), two VAD spans, and one prior `evict`
  /// event from before the fixture's own chunk window — one line for each
  /// event type `docs/data-formats.md` documents. Offsets from `base`:
  ///
  /// ```
  /// -7200        0    30   60  72       102        132
  ///   evict  ..  chunk1 chunk2 gap chunk3      chunk4
  ///              ^vad(2.14-9.88)  ^vad(75-100)
  ///              ^vad(9.88-25)
  /// ```
  private let indexJSONL = """
    {"t":"evict","file":"chunks/2026-07-17T08-30-00Z.m4a","start":"2026-07-17T08:30:00Z"}
    {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":1440000}
    {"t":"vad","state":"speech","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
    {"t":"vad","state":"silence","start":"2026-07-17T10:30:09.880Z","end":"2026-07-17T10:30:25.000Z"}
    {"t":"chunk","start":"2026-07-17T10:30:30Z","end":"2026-07-17T10:31:00Z","file":"chunks/2026-07-17T10-30-30Z.m4a","frames":1440000}
    {"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
    {"t":"chunk","start":"2026-07-17T10:31:12Z","end":"2026-07-17T10:31:42Z","file":"chunks/2026-07-17T10-31-12Z.m4a","frames":1440000}
    {"t":"vad","state":"speech","start":"2026-07-17T10:31:15.000Z","end":"2026-07-17T10:31:40.000Z"}
    {"t":"chunk","start":"2026-07-17T10:31:42Z","end":"2026-07-17T10:32:12Z","file":"chunks/2026-07-17T10-31-42Z.m4a","frames":1440000}
    """

  private func fixture() -> SourceFixture {
    SourceFixture(
      indexJSONL: indexJSONL,
      chunkFiles: [
        "2026-07-17T10-30-00Z.m4a",
        "2026-07-17T10-30-30Z.m4a",
        "2026-07-17T10-31-12Z.m4a",
        "2026-07-17T10-31-42Z.m4a",
      ]
    )
  }

  /// Reads `index.jsonl` back off disk through ``IndexLog/parse(_:)`` — the
  /// "created and read by EarsCore" step. Every other test in this suite
  /// reuses this to prove the same on-disk fixture drives every scenario.
  private func parsedFixtureEvents() throws -> [IndexEvent] {
    let fixture = fixture()
    let contents = try String(contentsOf: fixture.indexFileURL, encoding: .utf8)
    let result = IndexLog.parse(contents)
    #expect(result.malformedLines.isEmpty)
    #expect(result.events.count == 9)
    return result.events
  }

  @Test(
    "a fixture sources/<id>/ directory exists on disk with meta.toml, placeholder chunk files, and index.jsonl"
  )
  func fixtureDirectoryIsShapedLikeARealSource() {
    let fixture = fixture()
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: fixture.sourceDirectory.appendingPathComponent("meta.toml").path))
    #expect(fm.fileExists(atPath: fixture.indexFileURL.path))
    #expect(
      fm.fileExists(
        atPath: fixture.sourceDirectory.appendingPathComponent("chunks/2026-07-17T10-30-00Z.m4a")
          .path))
  }

  @Test(
    "reconstructs a range spanning a gap: chunks either side, the gap itself, and a clipped VAD span"
  )
  func reconstructsRangeSpanningGap() throws {
    let events = try parsedFixtureEvents()

    // 10:30:45 ..< 10:31:20 straddles the 10:31:00-10:31:12 capture gap.
    let requested = range(45, 80)
    let result = RangeReconstructor.reconstruct(requested, events: events)

    #expect(
      result.chunks.map(\.file) == [
        "chunks/2026-07-17T10-30-30Z.m4a",
        "chunks/2026-07-17T10-31-12Z.m4a",
      ])
    #expect(result.gaps == [range(60, 72)])
    // The second VAD speech span (75-100 from base) is clipped to the
    // requested window's trailing edge (45-80) and reported relative to
    // requested.start, per ReconstructedRange's documented convention.
    #expect(result.vadSpans == [VADSpan(state: .speech, start: 30, end: 35)])
  }

  @Test(
    "a range partially outside available chunks returns only what the index actually covers, without fabricating coverage"
  )
  func partiallyOutsideAvailableChunks() throws {
    let events = try parsedFixtureEvents()

    // 10:29:30 ..< 10:30:15: half of this precedes the first chunk
    // (base+0), which has no chunk/gap/vad event at all -- there is
    // nothing on record for it, so it must not show up as a synthesized
    // gap or chunk.
    let leading = RangeReconstructor.reconstruct(range(-30, 15), events: events)
    #expect(leading.chunks.map(\.file) == ["chunks/2026-07-17T10-30-00Z.m4a"])
    #expect(leading.gaps.isEmpty)
    // Millisecond-precision timestamps round-trip through ISO-8601 parsing
    // with a sub-microsecond `Double` error, so these compare with a
    // tolerance rather than bitwise equality (unlike the whole-second
    // fixtures elsewhere in this suite).
    #expect(leading.vadSpans.count == 2)
    #expect(leading.vadSpans[0].state == .speech)
    #expect(abs(leading.vadSpans[0].start - 32.14) < 0.001)
    #expect(abs(leading.vadSpans[0].end - 39.88) < 0.001)
    #expect(leading.vadSpans[1].state == .silence)
    #expect(abs(leading.vadSpans[1].start - 39.88) < 0.001)
    #expect(abs(leading.vadSpans[1].end - 45) < 0.001)

    // 10:32:20 ..< 10:32:50: entirely after the last known chunk (ends at
    // base+132) -- nothing to reconstruct, and that's not an error.
    let trailing = RangeReconstructor.reconstruct(range(140, 170), events: events)
    #expect(trailing.chunks.isEmpty)
    #expect(trailing.vadSpans.isEmpty)
    #expect(trailing.gaps.isEmpty)
  }

  @Test(
    "eviction math over the fixture's chunk list evicts the two oldest at a given time cap, ignoring the prior evict record"
  )
  func evictionOverFixtureChunks() throws {
    let events = try parsedFixtureEvents()

    // The fixture's one `evict` event is itself a record of a past
    // deletion, not a live chunk -- it must not appear in the chunk list
    // eviction math operates over.
    let chunks = events.compactMap { event -> IndexedChunk? in
      guard case .chunk(let start, let end, let file, let frames) = event else { return nil }
      return IndexedChunk(range: TimeRange(start: start, end: end), file: file, frames: frames)
    }
    #expect(chunks.count == 4)

    // now = the last chunk's end (base+132); a 60s cap sets the cutoff at
    // base+72, aging out the two chunks that end at base+30 and base+60.
    let now = base.advanced(by: 132)
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 60)

    #expect(
      evicted.map(\.file) == [
        "chunks/2026-07-17T10-30-00Z.m4a",
        "chunks/2026-07-17T10-30-30Z.m4a",
      ])
  }
}
