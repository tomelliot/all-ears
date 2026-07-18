import Foundation

/// Protocol seam over the actual audio-container write, per the "thin shim
/// over a hardware/model boundary" pattern in `docs/architecture.md`.
/// ``AVFoundationChunkFileWriter`` is the real (tier-2, `AVAudioFile`-backed)
/// conformance; tests inject a fake that can throw partway through a chunk
/// to exercise ``ChunkEncoder``'s keep-partial-on-failure path without
/// needing to force a real codec failure.
public protocol ChunkFileWriting: Sendable {
  /// Encodes and writes `samples` (mono, in `[-1, 1]`) to the file this
  /// writer was opened for. Called once per accumulated ``AudioBuffer`` in
  /// a chunk, in order.
  func write(samples: [Float]) throws

  /// Finalizes the file so it's a valid, readable container reflecting
  /// everything written so far -- called both on the normal end-of-chunk
  /// path and (best-effort) after a failed `write(samples:)`, so a partial
  /// chunk is still valid audio up to the point it failed.
  func finish() throws
}

/// Creates a ``ChunkFileWriting`` for `url` using `settings`. A factory
/// rather than a fixed type so ``ChunkEncoder`` can be constructed with a
/// fake in tests.
public typealias ChunkFileWriterFactory =
  @Sendable (URL, ChunkAudioSettings) throws ->
  any ChunkFileWriting
