/// Reconstructs the *live* ring-buffer contents — the chunks a source has
/// written but not yet evicted — from its append-only `index.jsonl` events.
///
/// This is the counterpart to ``RingBufferEviction`` (which decides *which*
/// live chunks have aged out): before the time-cap math can run after a daemon
/// restart, the set of chunks still on disk has to be recovered from the index,
/// because a fresh ``CaptureActor`` tracks only the chunks it writes in the
/// current process and knows nothing of prior runs.
///
/// A chunk is "live" when a `chunk` event wrote it and no later `evict` event
/// deleted it. Eviction is keyed on the chunk's `file` (see
/// ``EvictionExecutor``'s `evict(file:start:)`), and chunk filenames are unique
/// per chunk start, so matching a `chunk` to its `evict` by `file` path is
/// exact.
public enum RingBufferReconstruction {
  /// The chunks still on disk, oldest-first, reconstructed from `events`.
  ///
  /// - Parameter events: A source's index events, in any order (matching
  ///   ``IndexLog/parse(_:)``'s output — it need not be pre-sorted).
  /// - Returns: Every `chunk` event with no matching `evict`, as
  ///   ``IndexedChunk`` values sorted by start.
  public static func liveChunks(from events: [IndexEvent]) -> [IndexedChunk] {
    var evictedFiles: Set<String> = []
    for case .evict(let file, _) in events {
      evictedFiles.insert(file)
    }

    var chunks: [IndexedChunk] = []
    for case .chunk(let start, let end, let file, let frames) in events
    where !evictedFiles.contains(file) {
      chunks.append(
        IndexedChunk(range: TimeRange(start: start, end: end), file: file, frames: frames))
    }

    chunks.sort { $0.range.start < $1.range.start }
    return chunks
  }
}
