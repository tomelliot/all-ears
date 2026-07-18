import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory tests for ``EvictionExecutor`` -- tier-1 per
/// `docs/engineering-practices.md`. The eviction *decision* is
/// ``RingBufferEviction``, already tested in `EarsCoreTests`; these tests
/// cover the execution: does it delete the right files and append the right
/// events.
@Suite("EvictionExecutor")
struct EvictionExecutorTests {
  private func makeSourceDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EvictionExecutorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("chunks"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("asr"), withIntermediateDirectories: true)
    return dir
  }

  private func touch(_ url: URL) throws {
    try Data().write(to: url)
  }

  @Test("deletes both the chunks/ and asr/ copies of an evicted chunk")
  func deletesBothCopies() async throws {
    let sourceDirectory = try makeSourceDirectory()
    try touch(sourceDirectory.appendingPathComponent("chunks/old.m4a"))
    try touch(sourceDirectory.appendingPathComponent("asr/old.m4a"))

    let indexURL = sourceDirectory.appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    let oldChunk = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30)),
      file: "chunks/old.m4a",
      frames: 1_440_000
    )

    let evicted = try await EvictionExecutor.evict(
      chunks: [oldChunk],
      now: Instant(secondsSinceEpoch: 10_000),
      timeCapSeconds: 100,
      sourceDirectory: sourceDirectory,
      indexAppender: appender
    )

    #expect(evicted == [oldChunk])
    #expect(
      !FileManager.default.fileExists(
        atPath: sourceDirectory.appendingPathComponent("chunks/old.m4a").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: sourceDirectory.appendingPathComponent("asr/old.m4a").path))
  }

  @Test("appends an evict event referencing the chunk's indexed file path")
  func appendsEvictEvent() async throws {
    let sourceDirectory = try makeSourceDirectory()
    try touch(sourceDirectory.appendingPathComponent("chunks/old.m4a"))
    try touch(sourceDirectory.appendingPathComponent("asr/old.m4a"))

    let indexURL = sourceDirectory.appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    let oldChunk = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30)),
      file: "chunks/old.m4a",
      frames: 1_440_000
    )

    _ = try await EvictionExecutor.evict(
      chunks: [oldChunk],
      now: Instant(secondsSinceEpoch: 10_000),
      timeCapSeconds: 100,
      sourceDirectory: sourceDirectory,
      indexAppender: appender
    )

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events == [.evict(file: "chunks/old.m4a", start: Instant(secondsSinceEpoch: 0))])
  }

  @Test("a chunk within the time cap is neither deleted nor evicted")
  func withinCapUntouched() async throws {
    let sourceDirectory = try makeSourceDirectory()
    try touch(sourceDirectory.appendingPathComponent("chunks/recent.m4a"))
    try touch(sourceDirectory.appendingPathComponent("asr/recent.m4a"))

    let indexURL = sourceDirectory.appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    let recentChunk = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 9_980), end: Instant(secondsSinceEpoch: 10_000)),
      file: "chunks/recent.m4a",
      frames: 1_440_000
    )

    let evicted = try await EvictionExecutor.evict(
      chunks: [recentChunk],
      now: Instant(secondsSinceEpoch: 10_000),
      timeCapSeconds: 100,
      sourceDirectory: sourceDirectory,
      indexAppender: appender
    )

    #expect(evicted.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: sourceDirectory.appendingPathComponent("chunks/recent.m4a").path))
    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("tolerates a missing chunks/ copy (store_native = false sources never had one)")
  func toleratesMissingNativeCopy() async throws {
    let sourceDirectory = try makeSourceDirectory()
    try touch(sourceDirectory.appendingPathComponent("asr/old.m4a"))
    // No chunks/old.m4a on disk.

    let indexURL = sourceDirectory.appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    let oldChunk = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30)),
      file: "asr/old.m4a",
      frames: 1_440_000
    )

    let evicted = try await EvictionExecutor.evict(
      chunks: [oldChunk],
      now: Instant(secondsSinceEpoch: 10_000),
      timeCapSeconds: 100,
      sourceDirectory: sourceDirectory,
      indexAppender: appender
    )

    #expect(evicted == [oldChunk])
    #expect(
      !FileManager.default.fileExists(
        atPath: sourceDirectory.appendingPathComponent("asr/old.m4a").path))
  }

  @Test("evicts oldest-first across multiple aged-out chunks")
  func evictsOldestFirst() async throws {
    let sourceDirectory = try makeSourceDirectory()
    try touch(sourceDirectory.appendingPathComponent("chunks/a.m4a"))
    try touch(sourceDirectory.appendingPathComponent("chunks/b.m4a"))

    let indexURL = sourceDirectory.appendingPathComponent("index.jsonl")
    let appender = IndexAppender(fileURL: indexURL)

    let older = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30)),
      file: "chunks/a.m4a",
      frames: 1_440_000
    )
    let newer = IndexedChunk(
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 30), end: Instant(secondsSinceEpoch: 60)),
      file: "chunks/b.m4a",
      frames: 1_440_000
    )

    let evicted = try await EvictionExecutor.evict(
      chunks: [newer, older],
      now: Instant(secondsSinceEpoch: 10_000),
      timeCapSeconds: 100,
      sourceDirectory: sourceDirectory,
      indexAppender: appender
    )

    #expect(evicted == [older, newer])
  }
}

/// ``HardTotalCapEnforcement`` is a documented Phase 1 no-op seam -- these
/// tests pin that contract so a future accidental partial implementation
/// (evicting sometimes, e.g.) doesn't silently slip in unreviewed.
@Suite("HardTotalCapEnforcement")
struct HardTotalCapEnforcementTests {
  @Test("never evicts anything regardless of the configured cap")
  func neverEvicts() {
    #expect(
      HardTotalCapEnforcement.chunksToEvict(hardTotalCapBytes: 0, sources: []).isEmpty)
    #expect(
      HardTotalCapEnforcement.chunksToEvict(hardTotalCapBytes: 1, sources: ["mic"]).isEmpty)
    #expect(
      HardTotalCapEnforcement.chunksToEvict(
        hardTotalCapBytes: 1_000_000, sources: ["mic", "system"]
      )
      .isEmpty)
  }
}
