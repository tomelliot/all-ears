import EarsCore
import Foundation

/// Executes ring-buffer eviction: deletes aged-out chunk files and appends
/// the corresponding `evict` events, per `docs/data-formats.md`'s "Audio
/// chunks" section ("Chunks older than the source's time cap are deleted
/// oldest-first. Deletion is logged.").
///
/// The eviction *decision* (which chunks are aged out) is
/// ``RingBufferEviction/chunksToEvict(_:now:timeCapSeconds:)``, already
/// built and tested in `EarsCore` -- this type only calls it and executes
/// the result: delete files, append index events. It carries no state of
/// its own between calls, so it's a stateless `enum` rather than an actor;
/// the actual serialization against concurrent index writes is provided by
/// the shared ``IndexAppender`` passed in.
public enum EvictionExecutor {
  /// Evicts chunks aged out of `chunks` as of `now`, given `timeCapSeconds`.
  /// For each evicted chunk: deletes both the `chunks/` and `asr/` copies
  /// sharing the chunk's filename (either may already be absent -- a
  /// `store_native = false` source never had a `chunks/` copy, and a caller
  /// retrying after a partial failure may find one side already gone), then
  /// appends an `evict` event referencing the chunk's indexed `file` path.
  ///
  /// - Parameters:
  ///   - chunks: The source's known chunks (from ``IndexLog/parse(_:)`` +
  ///     ``RangeReconstructor``, or tracked incrementally by the caller).
  ///   - now: The current instant, always injected.
  ///   - timeCapSeconds: The source's `meta.toml` `time_cap_seconds`.
  ///   - sourceDirectory: The source's directory (containing `chunks/` and
  ///     `asr/`), from ``DataStoreLayout/sourceDirectory(dataRoot:sourceID:)``.
  ///   - indexAppender: The source's shared index writer.
  /// - Returns: The chunks that were evicted, oldest-first (mirroring
  ///   ``RingBufferEviction``'s own ordering).
  @discardableResult
  public static func evict(
    chunks: [IndexedChunk],
    now: Instant,
    timeCapSeconds: Double,
    sourceDirectory: URL,
    indexAppender: IndexAppender
  ) async throws -> [IndexedChunk] {
    let toEvict = RingBufferEviction.chunksToEvict(chunks, now: now, timeCapSeconds: timeCapSeconds)
    for chunk in toEvict {
      try deleteChunkFiles(for: chunk, sourceDirectory: sourceDirectory)
      try await indexAppender.append(.evict(file: chunk.file, start: chunk.range.start))
    }
    return toEvict
  }

  /// Evicts a source's aged-out chunks reading the live set straight from disk
  /// (``DiskChunkScan``) instead of from tracked/reconstructed chunks — the
  /// path the daemon's eviction sweep takes for a source with no live
  /// `CaptureActor` to route through. Otherwise identical to ``evict(chunks:…)``:
  /// same time-cap math, same file deletion, same `evict` events appended.
  ///
  /// - Parameter storeNative: The source's `meta.toml` `store_native`, selecting
  ///   the subdirectory whose filenames name the chunks (see ``DiskChunkScan``).
  @discardableResult
  public static func evictFromDisk(
    sourceDirectory: URL,
    storeNative: Bool,
    now: Instant,
    timeCapSeconds: Double,
    indexAppender: IndexAppender
  ) async throws -> [IndexedChunk] {
    let chunks = DiskChunkScan.liveChunks(
      sourceDirectory: sourceDirectory, storeNative: storeNative)
    return try await evict(
      chunks: chunks,
      now: now,
      timeCapSeconds: timeCapSeconds,
      sourceDirectory: sourceDirectory,
      indexAppender: indexAppender)
  }

  private static func deleteChunkFiles(for chunk: IndexedChunk, sourceDirectory: URL) throws {
    let filename = URL(fileURLWithPath: chunk.file).lastPathComponent
    for subdirectory in [ChunkSubdirectory.chunks, .asr] {
      let path = sourceDirectory.appendingPathComponent(subdirectory.rawValue)
        .appendingPathComponent(
          filename)
      guard FileManager.default.fileExists(atPath: path.path) else { continue }
      try FileManager.default.removeItem(at: path)
    }
  }
}
