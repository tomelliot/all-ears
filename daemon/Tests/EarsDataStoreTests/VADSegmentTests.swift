import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

@Suite("VADSegment writer + store")
struct VADSegmentTests {
  private func makeDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vad-seg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func at(_ seconds: Double) -> Instant { Instant(secondsSinceEpoch: seconds) }

  @Test("all spans land in one segment until a bound is crossed")
  func singleSegmentWhileUnderBounds() async throws {
    let dir = makeDir()
    let writer = VADSegmentWriter(directory: dir)
    for i in 0..<5 {
      try await writer.append(state: .speech, start: at(Double(i)), end: at(Double(i) + 0.5))
    }
    #expect(VADSegmentStore.segmentURLs(directory: dir).count == 1)
  }

  @Test("crossing the byte cap opens a new segment")
  func rollsOverOnBytes() async throws {
    let dir = makeDir()
    // A tiny cap so the second append rolls over.
    let writer = VADSegmentWriter(directory: dir, maxSegmentBytes: 80, maxSegmentSeconds: 1_000_000)
    try await writer.append(state: .speech, start: at(0), end: at(1))
    try await writer.append(state: .silence, start: at(1), end: at(2))
    try await writer.append(state: .speech, start: at(2), end: at(3))
    #expect(VADSegmentStore.segmentURLs(directory: dir).count >= 2)
  }

  @Test("crossing the time span opens a new segment")
  func rollsOverOnTime() async throws {
    let dir = makeDir()
    let writer = VADSegmentWriter(directory: dir, maxSegmentBytes: 8_000_000, maxSegmentSeconds: 10)
    try await writer.append(state: .speech, start: at(0), end: at(1))
    try await writer.append(state: .speech, start: at(5), end: at(6))
    try await writer.append(state: .speech, start: at(20), end: at(21))  // > 10s past segment start
    let segments = VADSegmentStore.segmentURLs(directory: dir)
    #expect(segments.count == 2)
    #expect(segments.map(\.start) == [at(0), at(20)])
  }

  @Test("events(overlapping:) returns only spans intersecting the range")
  func eventsOverlapping() async throws {
    let dir = makeDir()
    let writer = VADSegmentWriter(
      directory: dir, maxSegmentBytes: 100, maxSegmentSeconds: 1_000_000)
    try await writer.append(state: .speech, start: at(0), end: at(1))
    try await writer.append(state: .speech, start: at(100), end: at(101))
    try await writer.append(state: .speech, start: at(200), end: at(201))

    let events = VADSegmentStore.events(
      directory: dir, overlapping: TimeRange(start: at(95), end: at(150)))
    let starts = events.compactMap { event -> Double? in
      if case .vad(_, let s, _) = event { return s.secondsSinceEpoch }
      return nil
    }
    #expect(starts.contains(100))
    #expect(!starts.contains(200))
  }

  @Test("lastKnownEnd reports the newest segment's latest end")
  func lastKnownEndReadsNewest() async throws {
    let dir = makeDir()
    let writer = VADSegmentWriter(directory: dir, maxSegmentBytes: 80, maxSegmentSeconds: 1_000_000)
    try await writer.append(state: .speech, start: at(0), end: at(1))
    try await writer.append(state: .speech, start: at(50), end: at(60))
    #expect(VADSegmentStore.lastKnownEnd(directory: dir) == at(60))
  }

  @Test("evict unlinks fully-aged segments but never the newest")
  func evictsAgedSegments() async throws {
    let dir = makeDir()
    let writer = VADSegmentWriter(directory: dir, maxSegmentBytes: 80, maxSegmentSeconds: 1_000_000)
    // Three segments starting at 0, ~1, ~2 (byte cap forces rollover each append).
    try await writer.append(state: .speech, start: at(0), end: at(1))
    try await writer.append(state: .speech, start: at(1_000), end: at(1_001))
    try await writer.append(state: .speech, start: at(2_000), end: at(2_001))
    #expect(VADSegmentStore.segmentURLs(directory: dir).count == 3)

    // Cutoff past the second segment's start: the first is fully older (the
    // next segment starts before the cutoff); the newest is always kept.
    let removed = try VADSegmentStore.evict(directory: dir, olderThan: at(1_500))
    #expect(removed.count == 1)
    let remaining = VADSegmentStore.segmentURLs(directory: dir).map(\.start)
    #expect(remaining == [at(1_000), at(2_000)])
  }

  @Test("a restart resumes into the newest existing segment")
  func resumesNewestSegment() async throws {
    let dir = makeDir()
    let first = VADSegmentWriter(
      directory: dir, maxSegmentBytes: 8_000_000, maxSegmentSeconds: 1_000)
    try await first.append(state: .speech, start: at(0), end: at(1))
    let afterFirst = VADSegmentStore.segmentURLs(directory: dir).map(\.start)

    // A fresh writer (as after a daemon restart) continues the same segment.
    let second = VADSegmentWriter(
      directory: dir, maxSegmentBytes: 8_000_000, maxSegmentSeconds: 1_000)
    try await second.append(state: .speech, start: at(2), end: at(3))
    #expect(VADSegmentStore.segmentURLs(directory: dir).map(\.start) == afterFirst)
  }
}
