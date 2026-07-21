import Testing

@testable import EarsCore

/// Covers ``RingBufferReconstruction/liveChunks(from:)``: recovering the
/// still-on-disk chunk set from a source's index events by pairing `chunk`
/// events with their `evict` events.
@Suite("RingBufferReconstruction")
struct RingBufferReconstructionTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func chunk(_ start: Double, _ end: Double, file: String, frames: Int = 1) -> IndexEvent {
    .chunk(start: base.advanced(by: start), end: base.advanced(by: end), file: file, frames: frames)
  }

  private func evict(_ start: Double, file: String) -> IndexEvent {
    .evict(file: file, start: base.advanced(by: start))
  }

  @Test("empty index yields no live chunks")
  func emptyInput() {
    #expect(RingBufferReconstruction.liveChunks(from: []).isEmpty)
  }

  @Test("chunks with no evictions are all live, oldest-first")
  func allLive() {
    let events = [
      chunk(60, 90, file: "chunks/c.m4a"),
      chunk(0, 30, file: "chunks/a.m4a"),
      chunk(30, 60, file: "chunks/b.m4a"),
    ]
    let live = RingBufferReconstruction.liveChunks(from: events)
    #expect(live.map(\.file) == ["chunks/a.m4a", "chunks/b.m4a", "chunks/c.m4a"])
  }

  @Test("an evicted chunk is dropped, others retained")
  func evictedDropped() {
    let events = [
      chunk(0, 30, file: "chunks/old.m4a"),
      chunk(30, 60, file: "chunks/keep.m4a"),
      evict(0, file: "chunks/old.m4a"),
    ]
    let live = RingBufferReconstruction.liveChunks(from: events)
    #expect(live.map(\.file) == ["chunks/keep.m4a"])
  }

  @Test("eviction order relative to the chunk event doesn't matter")
  func evictBeforeChunkInInput() {
    // IndexLog.parse sorts by start, so an evict (keyed on the chunk's start)
    // can precede its chunk in the parsed stream; matching is by file, not
    // position.
    let events = [
      evict(0, file: "chunks/old.m4a"),
      chunk(0, 30, file: "chunks/old.m4a"),
      chunk(30, 60, file: "chunks/keep.m4a"),
    ]
    let live = RingBufferReconstruction.liveChunks(from: events)
    #expect(live.map(\.file) == ["chunks/keep.m4a"])
  }

  @Test("live chunk ranges and frames are preserved")
  func preservesPayload() {
    let events = [chunk(0, 30, file: "chunks/a.m4a", frames: 1440)]
    let live = RingBufferReconstruction.liveChunks(from: events)
    #expect(live.count == 1)
    #expect(live[0].range == TimeRange(start: base, end: base.advanced(by: 30)))
    #expect(live[0].frames == 1440)
  }
}
