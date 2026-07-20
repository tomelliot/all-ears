import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-file tests for ``IndexAppender`` -- tier-1 per
/// `docs/engineering-practices.md`.
@Suite("IndexAppender")
struct IndexAppenderTests {
  private func makeIndexURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "IndexAppenderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("index.jsonl")
  }

  @Test("appending creates the file and parent directory on first write")
  func createsFileOnFirstWrite() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "IndexAppenderTests-\(UUID().uuidString)")
    let indexURL = dir.appendingPathComponent("nested").appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0),
        end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a",
        frames: 1_440_000
      ))

    #expect(FileManager.default.fileExists(atPath: indexURL.path))
  }

  @Test("each append is one JSON line, in append order")
  func appendsOneLinePerEvent() async throws {
    let indexURL = try makeIndexURL()
    let appender = IndexAppender(fileURL: indexURL)

    let first = IndexEvent.chunk(
      start: Instant(secondsSinceEpoch: 0),
      end: Instant(secondsSinceEpoch: 30),
      file: "chunks/a.m4a",
      frames: 1_440_000
    )
    let second = IndexEvent.chunk(
      start: Instant(secondsSinceEpoch: 30),
      end: Instant(secondsSinceEpoch: 60),
      file: "chunks/b.m4a",
      frames: 1_440_000
    )
    try await appender.append(first)
    try await appender.append(second)

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)

    let parsed = IndexLog.parse(contents)
    #expect(parsed.malformedLines.isEmpty)
    #expect(parsed.events == [first, second])
  }

  @Test("readContents returns empty string before any write")
  func readContentsEmptyBeforeWrite() async throws {
    let indexURL = try makeIndexURL()
    let appender = IndexAppender(fileURL: indexURL)
    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("readContents reflects appended events")
  func readContentsReflectsAppends() async throws {
    let indexURL = try makeIndexURL()
    let appender = IndexAppender(fileURL: indexURL)
    let event = IndexEvent.gap(
      start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 10),
      reason: "daemon_restart")
    try await appender.append(event)

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events == [event])
  }

  @Test("subsequent appends land after prior writer sessions are closed (no lost writes)")
  func manyAppendsAllLand() async throws {
    let indexURL = try makeIndexURL()
    let appender = IndexAppender(fileURL: indexURL)

    for index in 0..<20 {
      try await appender.append(
        .evict(file: "chunks/\(index).m4a", start: Instant(secondsSinceEpoch: Double(index))))
    }

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 20)
    #expect(parsed.malformedLines.isEmpty)
  }

  @Test("lastKnownEnd returns nil for a non-existent index")
  func lastKnownEndNonExistent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "IndexAppenderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let appender = IndexAppender(fileURL: dir.appendingPathComponent("never-written.jsonl"))

    let end = try await appender.lastKnownEnd()
    #expect(end == nil)
  }

  @Test("lastKnownEnd returns the max end across chunk/vad/gap events")
  func lastKnownEndAcrossEventTypes() async throws {
    let appender = IndexAppender(fileURL: try makeIndexURL())
    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a", frames: 1_440_000))
    try await appender.append(
      .vad(
        state: .speech, start: Instant(secondsSinceEpoch: 30), end: Instant(secondsSinceEpoch: 35)))
    try await appender.append(
      .gap(
        start: Instant(secondsSinceEpoch: 35), end: Instant(secondsSinceEpoch: 60), reason: "test"))
    try await appender.append(
      .evict(file: "chunks/old.m4a", start: Instant(secondsSinceEpoch: 5)))

    let end = try await appender.lastKnownEnd()
    #expect(end == Instant(secondsSinceEpoch: 60))
  }

  @Test("lastKnownEnd scans only the tail of a multi-megabyte index without parsing the whole file")
  func lastKnownEndScansOnlyTail() async throws {
    // A regression guard: before ``lastKnownEnd()``, ``StartupGapAppender``
    // read and parsed the entire index on every daemon restart. A multi-day
    // run accumulates a multi-megabyte `index.jsonl` that blocked
    // ``CaptureActor.start()`` for seconds — leaving the source stuck
    // `.disabled` and the control plane unreachable. This test writes far
    // more than the tail-scan chunk size and asserts the latest end is
    // returned without reading the whole file.
    let appender = IndexAppender(fileURL: try makeIndexURL())

    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a", frames: 1_440_000))
    let evictCount = 2_000
    for index in 0..<evictCount {
      try await appender.append(
        .evict(file: "chunks/\(index).m4a", start: Instant(secondsSinceEpoch: Double(index))))
    }
    let latestEnd = Instant(secondsSinceEpoch: 9_999)
    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 9_990), end: latestEnd,
        file: "chunks/final.m4a", frames: 1_440_000))

    let end = try await appender.lastKnownEnd()
    #expect(end == latestEnd)
  }

  @Test("lastKnownEnd keeps scanning backward when the tail is exclusively evict events")
  func lastKnownEndScansPastEvictTail() async throws {
    // Coverage events only at the head, then a long evict-only tail:
    // the first backward block finds no coverage and must keep going.
    let appender = IndexAppender(fileURL: try makeIndexURL())
    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a", frames: 1_440_000))
    for index in 0..<2_000 {
      try await appender.append(
        .evict(file: "chunks/\(index).m4a", start: Instant(secondsSinceEpoch: Double(index))))
    }

    let end = try await appender.lastKnownEnd()
    #expect(end == Instant(secondsSinceEpoch: 30))
  }
}
