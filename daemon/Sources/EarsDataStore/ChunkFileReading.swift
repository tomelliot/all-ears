import Foundation

/// Protocol seam over reading a chunk file's PCM samples back, per the "thin
/// shim over a hardware/model boundary" pattern in `docs/architecture.md` --
/// the read-side mirror of ``ChunkFileWriting``. ``MmapPCMChunkFileReader``
/// is the real, `mmap`-backed conformance; tests can inject a fake.
///
/// Conformers read **raw interleaved mono `Float32` PCM** files: the format
/// this module's fixtures and ``AsrChunkRangeReader`` operate on. Production
/// `asr/` chunk files are AAC/Opus containers written via `AVAudioFile`
/// (``ChunkAudioSettings``); decoding those into this raw, `mmap`-able form
/// is a follow-up thin shim (symmetric to ``AVFoundationChunkFileWriter`` on
/// the write side) for whoever wires the real `transcribe` CLI -- out of
/// scope here, which builds the constant-memory, disk-backed read path and
/// its consumers against fixture chunk files.
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
