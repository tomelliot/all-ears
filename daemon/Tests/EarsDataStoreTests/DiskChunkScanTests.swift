import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory tests for the filename-driven eviction path
/// (``DiskChunkScan`` + ``EvictionExecutor/evictFromDisk``) — the seam the
/// daemon's sweep uses for a source with no live actor. The chunk files are
/// named exactly as the encoder names them (``FilenameTimestampCodec``), so the
/// scan round-trips real filenames rather than hand-built ranges.
@Suite("DiskChunkScan")
struct DiskChunkScanTests {
  private func makeSourceDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DiskChunkScanTests-\(UUID().uuidString)")
    for subdirectory in ["chunks", "asr"] {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(subdirectory), withIntermediateDirectories: true)
    }
    return dir
  }

  /// Writes an empty chunk file named for `start` in `subdirectory`, returning
  /// its source-relative path.
  @discardableResult
  private func writeChunk(_ start: Instant, in subdirectory: String, of directory: URL) throws
    -> String
  {
    let filename = FilenameTimestampCodec.string(for: start) + ".m4a"
    try Data().write(
      to: directory.appendingPathComponent(subdirectory).appendingPathComponent(filename))
    return "\(subdirectory)/\(filename)"
  }

  @Test("reconstructs contiguous chunks oldest-first, newest ending at its own start")
  func reconstructsContiguousChunks() throws {
    let directory = try makeSourceDirectory()
    let starts = [1_000_000.0, 1_000_030.0, 1_000_060.0].map { Instant(secondsSinceEpoch: $0) }
    // Written out of order to prove the scan sorts.
    for start in [starts[2], starts[0], starts[1]] {
      try writeChunk(start, in: "chunks", of: directory)
    }

    let chunks = DiskChunkScan.liveChunks(sourceDirectory: directory, storeNative: true)

    #expect(chunks.map(\.range.start) == starts)
    // Each end is the next start; the newest chunk's end is its own start.
    #expect(chunks.map(\.range.end) == [starts[1], starts[2], starts[2]])
    #expect(chunks.allSatisfy { $0.file.hasPrefix("chunks/") })
  }

  @Test("reads the asr/ subdirectory when store_native is false")
  func readsAsrWhenNotStoringNative() throws {
    let directory = try makeSourceDirectory()
    let start = Instant(secondsSinceEpoch: 1_000_000)
    try writeChunk(start, in: "asr", of: directory)
    // A stray chunks/ copy must be ignored when store_native is false.
    try writeChunk(start, in: "chunks", of: directory)

    let chunks = DiskChunkScan.liveChunks(sourceDirectory: directory, storeNative: false)

    #expect(chunks.count == 1)
    #expect(chunks[0].file.hasPrefix("asr/"))
  }

  @Test("evictFromDisk deletes only aged files and logs matching evict events")
  func evictFromDiskDeletesAgedOnly() async throws {
    let directory = try makeSourceDirectory()
    let oldFile = try writeChunk(Instant(secondsSinceEpoch: 1_000_000), in: "chunks", of: directory)
    _ = try writeChunk(Instant(secondsSinceEpoch: 1_000_030), in: "chunks", of: directory)
    _ = try writeChunk(Instant(secondsSinceEpoch: 1_000_060), in: "chunks", of: directory)

    let appender = IndexAppender(fileURL: directory.appendingPathComponent("index.jsonl"))
    // cutoff = 1_000_050: only the first chunk (end 1_000_030) is strictly past it.
    let evicted = try await EvictionExecutor.evictFromDisk(
      sourceDirectory: directory,
      storeNative: true,
      now: Instant(secondsSinceEpoch: 1_000_100),
      timeCapSeconds: 50,
      indexAppender: appender)

    #expect(evicted.map(\.file) == [oldFile])
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(oldFile).path))

    // The evict event names the same file path the encoder's chunk event would,
    // so index reconstruction masks the deleted chunk.
    let parsed = IndexLog.parse(try await appender.readContents())
    #expect(
      parsed.events == [.evict(file: oldFile, start: Instant(secondsSinceEpoch: 1_000_000))])
  }

  @Test("a source idle past the cap has even its newest chunk expired")
  func idleSourceFullyExpired() async throws {
    let directory = try makeSourceDirectory()
    for seconds in [1_000_000.0, 1_000_030.0, 1_000_060.0] {
      try writeChunk(Instant(secondsSinceEpoch: seconds), in: "chunks", of: directory)
    }

    let appender = IndexAppender(fileURL: directory.appendingPathComponent("index.jsonl"))
    // now is far past the newest chunk, so the whole source is behind the cap.
    let evicted = try await EvictionExecutor.evictFromDisk(
      sourceDirectory: directory,
      storeNative: true,
      now: Instant(secondsSinceEpoch: 1_100_000),
      timeCapSeconds: 100,
      indexAppender: appender)

    #expect(evicted.count == 3)
    let remaining = try FileManager.default.contentsOfDirectory(
      atPath: directory.appendingPathComponent("chunks").path)
    #expect(remaining.isEmpty)
  }
}
