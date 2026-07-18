import Testing

@testable import EarsCore

/// Covers ``IndexLog/parse(_:)``: parsing a whole `index.jsonl` file's contents
/// into ordered events, and the documented defensive behaviour for malformed or
/// out-of-order lines (see that type's doc comment).
@Suite("IndexLog")
struct IndexLogTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  @Test("parses an empty file into no events")
  func empty() {
    let result = IndexLog.parse("")
    #expect(result.events.isEmpty)
    #expect(result.malformedLines.isEmpty)
  }

  @Test("parses blank lines as no-ops, not malformed")
  func blankLines() {
    let result = IndexLog.parse("\n\n   \n")
    #expect(result.events.isEmpty)
    #expect(result.malformedLines.isEmpty)
  }

  @Test("parses one event per line, in file order when already ordered")
  func multipleLines() {
    let contents = """
      {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/a.m4a","frames":480000}
      {"t":"vad","state":"speech","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
      {"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
      """
    let result = IndexLog.parse(contents)
    #expect(result.events.count == 3)
    #expect(result.malformedLines.isEmpty)
    guard case .chunk = result.events[0] else {
      Issue.record("expected chunk first, got \(result.events[0])")
      return
    }
    guard case .vad = result.events[1] else {
      Issue.record("expected vad second, got \(result.events[1])")
      return
    }
    guard case .gap = result.events[2] else {
      Issue.record("expected gap third, got \(result.events[2])")
      return
    }
  }

  @Test(
    "skips a malformed line and records its 1-based line number, without dropping valid neighbours")
  func malformedLineIsSkippedAndNoted() {
    let contents = """
      {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/a.m4a","frames":480000}
      not even json
      {"t":"evict","file":"chunks/old.m4a","start":"2026-07-17T08:30:00Z"}
      """
    let result = IndexLog.parse(contents)
    #expect(result.events.count == 2)
    #expect(result.malformedLines == [2])
  }

  @Test(
    "sorts events by start instant regardless of file order (defensive against out-of-order lines)")
  func defensiveSort() {
    // The gap line appears before the chunk line in the file, but the
    // chunk's start precedes the gap's start; reconstruction and eviction
    // both need chronological order, so parse() sorts rather than trusting
    // append order.
    let contents = """
      {"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
      {"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/a.m4a","frames":480000}
      """
    let result = IndexLog.parse(contents)
    #expect(result.events.count == 2)
    #expect(result.events[0].start == base)
    #expect(result.events[1].start == base.advanced(by: 60))
  }
}
