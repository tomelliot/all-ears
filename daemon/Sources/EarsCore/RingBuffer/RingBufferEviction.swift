/// Pure time-cap math for a source's ring buffer: given known chunks and a
/// retention window, decides which chunks have aged out. Actually deleting
/// the files (and appending the corresponding `evict` events to
/// `index.jsonl`) is a later, I/O-owning phase's job — this is math only.
public enum RingBufferEviction {
  /// Chunks older than `now - timeCapSeconds`, oldest-first.
  ///
  /// A chunk is "older than the cap" when its coverage ends *before* the
  /// cutoff instant; a chunk ending exactly at the cutoff is retained. This
  /// mirrors ``TimeRange``'s half-open `[start, end)` convention used
  /// throughout the suite: the retention window is treated as
  /// `[cutoff, now]`, inclusive of its lower edge, so a chunk is evicted
  /// only once it falls strictly outside that window.
  ///
  /// - Parameters:
  ///   - chunks: Known chunks, in any order.
  ///   - now: The current instant (always injected — see ``NowProviding``;
  ///     this function never reads the wall clock itself).
  ///   - timeCapSeconds: The source's ring-buffer window, in seconds
  ///     (`meta.toml`'s `time_cap_seconds`).
  /// - Returns: Aged-out chunks, ordered oldest-first by their end instant.
  public static func chunksToEvict(
    _ chunks: [IndexedChunk],
    now: Instant,
    timeCapSeconds: Double
  ) -> [IndexedChunk] {
    let cutoff = now.advanced(by: -timeCapSeconds)
    return
      chunks
      .filter { $0.range.end < cutoff }
      .sorted { $0.range.end < $1.range.end }
  }
}
