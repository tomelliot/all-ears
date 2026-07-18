import Foundation

/// Protocol seam over reading a chunk file's PCM samples back, per the "thin
/// shim over a hardware/model boundary" pattern in `docs/architecture.md` --
/// the read-side mirror of ``ChunkFileWriting``. Two conformances exist:
/// ``AVFoundationChunkFileReader``, the real `AVAudioFile`-backed decoder for
/// production `asr/` chunk files (AAC/Opus containers written via
/// ``ChunkAudioSettings``/``AVFoundationChunkFileWriter``), and the default
/// ``AsrChunkRangeReader``/``SegmentedAudioReader`` use; and
/// ``MmapPCMChunkFileReader``, an `mmap`-backed reader of **raw interleaved
/// mono `Float32` PCM** files, kept for fixture tests that want exact-sample
/// assertions a lossy codec round-trip can't give. Tests can also inject a
/// fake ``ChunkFileReading`` directly.
public protocol ChunkFileReading: Sendable {
  /// Total sample (frame) count available in this chunk file -- the
  /// authoritative source of truth for how much audio actually landed on
  /// disk (rather than trusting `index.jsonl`'s `frames`, which records the
  /// *native*-domain frame count per ``ChunkEncoder``'s doc comment, not
  /// this feed's own sample count).
  var frameCount: Int { get }

  /// Reads `range` (frame indices within `0..<frameCount`) as mono `Float32`
  /// samples in `[-1, 1]`.
  ///
  /// - Throws: ``DataStoreError/chunkRangeOutOfBounds(requested:available:)``
  ///   if `range` isn't fully contained in `0..<frameCount`.
  func read(frames range: Range<Int>) throws -> [Float]
}

/// Creates a ``ChunkFileReading`` for `url`. A factory rather than a fixed
/// type so callers can inject a fake in tests, matching
/// ``ChunkFileWriterFactory``'s pattern on the write side.
public typealias ChunkFileReaderFactory =
  @Sendable (URL) throws ->
  any ChunkFileReading
