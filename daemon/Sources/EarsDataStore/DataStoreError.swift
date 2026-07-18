import EarsCore

/// Errors this module's I/O-owning types raise, distinct from
/// ``DescriptorTOMLError`` (which covers only the pure TOML-content mapping
/// already owned by `EarsConfig`).
public enum DataStoreError: Error, Sendable, Hashable {
  /// `meta.toml` doesn't exist for the given source.
  case sourceMetaNotFound(SourceID)
  /// `session.toml` doesn't exist for the given session id.
  case sessionNotFound(String)
  /// An ``AudioBuffer`` was appended to a ``ChunkEncoder`` at a sample rate
  /// other than the encoder's configured native rate.
  case sampleRateMismatch(expected: Int, got: Int)
  /// An `AVAudioFormat`/`AVAudioPCMBuffer` could not be constructed for the
  /// requested sample rate/channel combination.
  case invalidAudioFormat
  /// Resampling the native feed down to the ASR rate failed.
  case resampleFailed
  /// A write was attempted on a ``ChunkFileWriting`` after ``ChunkFileWriting/finish()``.
  case writerClosed
  /// A chunk finished encoding with fewer frames written than were
  /// appended, because the native and/or ASR feed's encoder threw partway
  /// through. The partial chunk file(s) already on disk are kept (see
  /// `docs/specs/capture-daemon.md`'s "Ring buffer maintenance"); this error
  /// reports which feed(s) failed so a caller can log it.
  case partialChunkWrite(nativeFailed: Bool, asrFailed: Bool)
}
