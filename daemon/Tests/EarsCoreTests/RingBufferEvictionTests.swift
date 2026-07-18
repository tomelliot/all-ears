import Testing

@testable import EarsCore

/// Covers ``RingBufferEviction/chunksToEvict(_:now:timeCapSeconds:)``: pure
/// time-cap math over known chunks. Actually deleting files is a later
/// phase's job — this only decides which chunks are old enough to go.
@Suite("RingBufferEviction")
struct RingBufferEvictionTests {
  private let now = Instant(secondsSinceEpoch: 1_784_284_200)

  private func chunk(endingSecondsAgo secondsAgo: Double, file: String) -> IndexedChunk {
    let end = now.advanced(by: -secondsAgo)
    return IndexedChunk(
      range: TimeRange(start: end.advanced(by: -30), end: end), file: file, frames: 1)
  }

  @Test("empty input evicts nothing")
  func emptyInput() {
    let evicted = RingBufferEviction.chunksToEvict([], now: now, timeCapSeconds: 3600)
    #expect(evicted.isEmpty)
  }

  @Test("a chunk ending well before the cutoff is evicted")
  func belowCapBoundary() {
    let chunks = [chunk(endingSecondsAgo: 3700, file: "chunks/old.m4a")]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 3600)
    #expect(evicted.map(\.file) == ["chunks/old.m4a"])
  }

  @Test(
    "a chunk ending exactly at the cutoff is retained (cutoff is the inclusive edge of the retention window)"
  )
  func atCapBoundary() {
    let chunks = [chunk(endingSecondsAgo: 3600, file: "chunks/boundary.m4a")]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 3600)
    #expect(evicted.isEmpty)
  }

  @Test("a chunk ending after the cutoff (more recent) is retained")
  func aboveCapBoundary() {
    let chunks = [chunk(endingSecondsAgo: 1800, file: "chunks/recent.m4a")]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 3600)
    #expect(evicted.isEmpty)
  }

  @Test("multiple aged-out chunks are returned oldest-first")
  func oldestFirstOrdering() {
    let chunks = [
      chunk(endingSecondsAgo: 3900, file: "chunks/newer-of-the-old.m4a"),
      chunk(endingSecondsAgo: 7200, file: "chunks/oldest.m4a"),
      chunk(endingSecondsAgo: 5000, file: "chunks/middle.m4a"),
    ]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 3600)
    #expect(
      evicted.map(\.file) == [
        "chunks/oldest.m4a", "chunks/middle.m4a", "chunks/newer-of-the-old.m4a",
      ])
  }

  @Test("retained chunks are excluded even when mixed with aged-out ones")
  func mixedRetainedAndEvicted() {
    let chunks = [
      chunk(endingSecondsAgo: 100, file: "chunks/recent.m4a"),
      chunk(endingSecondsAgo: 9999, file: "chunks/ancient.m4a"),
    ]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 3600)
    #expect(evicted.map(\.file) == ["chunks/ancient.m4a"])
  }

  @Test("a zero time cap evicts every chunk that isn't ending exactly at now")
  func zeroTimeCap() {
    let chunks = [chunk(endingSecondsAgo: 1, file: "chunks/a.m4a")]
    let evicted = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: 0)
    #expect(evicted.map(\.file) == ["chunks/a.m4a"])
  }
}
