import Testing

@testable import EarsCore

/// Covers ``RangeReconstructor/reconstruct(_:events:)``: mapping a requested
/// wall-clock ``TimeRange`` plus a source's index events to the chunks, VAD
/// spans, and gaps relevant to it.
@Suite("RangeReconstructor")
struct RangeReconstructionTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func chunk(_ start: Double, _ end: Double, file: String, frames: Int = 1) -> IndexEvent {
    .chunk(start: base.advanced(by: start), end: base.advanced(by: end), file: file, frames: frames)
  }

  private func vad(_ state: VADState, _ start: Double, _ end: Double) -> IndexEvent {
    .vad(state: state, start: base.advanced(by: start), end: base.advanced(by: end))
  }

  private func gap(_ start: Double, _ end: Double, reason: String = "daemon_restart") -> IndexEvent
  {
    .gap(start: base.advanced(by: start), end: base.advanced(by: end), reason: reason)
  }

  private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: base.advanced(by: start), end: base.advanced(by: end))
  }

  @Test("empty index yields an empty reconstruction")
  func emptyInput() {
    let result = RangeReconstructor.reconstruct(range(0, 30), events: [])
    #expect(result.chunks.isEmpty)
    #expect(result.vadSpans.isEmpty)
    #expect(result.gaps.isEmpty)
    #expect(result.requested == range(0, 30))
  }

  @Test(
    "a single chunk and vad span fully inside the range are both included, with vad offsets relative to the range start"
  )
  func noGaps() {
    let events: [IndexEvent] = [
      chunk(0, 30, file: "chunks/a.m4a"),
      vad(.speech, 2, 10),
    ]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.chunks.map(\.file) == ["chunks/a.m4a"])
    #expect(result.vadSpans == [VADSpan(state: .speech, start: 2, end: 10)])
    #expect(result.gaps.isEmpty)
  }

  @Test("a gap fully inside the range is reported unclipped")
  func gapFullyInside() {
    let events: [IndexEvent] = [
      chunk(0, 60, file: "chunks/a.m4a"),
      gap(20, 30),
    ]
    let result = RangeReconstructor.reconstruct(range(0, 60), events: events)
    #expect(result.gaps == [range(20, 30)])
  }

  @Test("a gap overlapping the range's leading boundary is clipped to the range")
  func gapOverlapsLeadingBoundary() {
    let events: [IndexEvent] = [gap(-10, 10)]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.gaps == [range(0, 10)])
  }

  @Test("a gap overlapping the range's trailing boundary is clipped to the range")
  func gapOverlapsTrailingBoundary() {
    let events: [IndexEvent] = [gap(25, 40)]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.gaps == [range(25, 30)])
  }

  @Test("multiple overlapping chunks are all included, ordered by start")
  func multipleChunks() {
    let events: [IndexEvent] = [
      chunk(30, 60, file: "chunks/b.m4a"),
      chunk(0, 30, file: "chunks/a.m4a"),
      chunk(60, 90, file: "chunks/c.m4a"),
    ]
    let result = RangeReconstructor.reconstruct(range(15, 75), events: events)
    #expect(result.chunks.map(\.file) == ["chunks/a.m4a", "chunks/b.m4a", "chunks/c.m4a"])
  }

  @Test("events entirely outside the requested range are excluded")
  func eventsOutsideRangeExcluded() {
    let events: [IndexEvent] = [
      chunk(-60, -30, file: "chunks/before.m4a"),
      chunk(100, 130, file: "chunks/after.m4a"),
      vad(.speech, -20, -5),
      vad(.silence, 200, 210),
      gap(-40, -35),
      gap(500, 510),
    ]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.chunks.isEmpty)
    #expect(result.vadSpans.isEmpty)
    #expect(result.gaps.isEmpty)
  }

  @Test("touching chunk/gap/vad boundaries do not overlap, per the half-open convention")
  func touchingBoundariesExcluded() {
    let events: [IndexEvent] = [
      chunk(-30, 0, file: "chunks/before.m4a"),
      chunk(30, 60, file: "chunks/after.m4a"),
      vad(.speech, -10, 0),
      gap(30, 40),
    ]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.chunks.isEmpty)
    #expect(result.vadSpans.isEmpty)
    #expect(result.gaps.isEmpty)
  }

  @Test("evict events do not affect reconstruction")
  func evictEventsIgnored() {
    let events: [IndexEvent] = [
      chunk(0, 30, file: "chunks/a.m4a"),
      .evict(file: "chunks/old.m4a", start: base.advanced(by: -7200)),
    ]
    let result = RangeReconstructor.reconstruct(range(0, 30), events: events)
    #expect(result.chunks.map(\.file) == ["chunks/a.m4a"])
  }
}
