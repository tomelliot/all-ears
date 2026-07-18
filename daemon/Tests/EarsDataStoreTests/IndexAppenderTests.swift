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
}
