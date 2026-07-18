import AVFoundation

/// The real ``ChunkFileReading`` conformance: decodes a real encoded chunk
/// file (AAC in `.m4a`, or Opus in `.caf`, per ``ChunkAudioSettings``) back
/// into mono `Float32` PCM via `AVAudioFile` -- the read-side mirror of
/// ``AVFoundationChunkFileWriter``, and the production default for
/// ``AsrChunkRangeReader``/``SegmentedAudioReader``'s `readerFactory` (see
/// their doc comments). ``MmapPCMChunkFileReader`` was the placeholder
/// default before this type existed; it remains as a real, still-used
/// conformance for the raw-`Float32`-PCM fixtures the stitching/boundary
/// logic tests are built on (exact-sample assertions that a lossy codec
/// round-trip can't give), but production `asr/` chunk files are never raw
/// PCM, so it is no longer the default a caller gets for free.
///
/// Requesting `commonFormat: .pcmFormatFloat32, interleaved: false` on the
/// *reading* initializer (mirroring the writer's writing initializer) makes
/// `AVAudioFile` run the container's decoder internally and hand back
/// already-decoded PCM through `processingFormat` -- this type never touches
/// compressed bytes directly.
///
/// A `final class` (not a `struct`) for the same reason as
/// ``AVFoundationChunkFileWriter``: `AVAudioFile` owns a live file handle,
/// and seeking (`framePosition`) before each `read(frames:)` is inherently
/// stateful. `AVAudioFile` isn't documented `Sendable`; this type is only
/// ever driven from within one ``AsrChunkRangeReader/read(_:chunks:)`` call
/// at a time, never shared across concurrent callers, so `@unchecked
/// Sendable` is the same "thin shim behind a protocol" exception
/// ``AVFoundationChunkFileWriter`` already takes.
public final class AVFoundationChunkFileReader: ChunkFileReading, @unchecked Sendable {
  private let file: AVAudioFile
  public let frameCount: Int
  public let sampleRate: Double

  public init(url: URL) throws {
    file = try AVAudioFile(
      forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    frameCount = Int(file.length)
    sampleRate = file.processingFormat.sampleRate
  }

  /// - Throws: ``DataStoreError/chunkRangeOutOfBounds(requested:available:)``
  ///   if `range` isn't fully contained in `0..<frameCount`, matching
  ///   ``MmapPCMChunkFileReader``'s contract exactly so both
  ///   ``ChunkFileReading`` conformances behave identically at this
  ///   boundary -- callers (``AsrChunkRangeReader``) already clamp against
  ///   this reader's own `frameCount` before calling, so a real out-of-bounds
  ///   request here indicates a caller bug, not a normal codec-priming
  ///   frame-count mismatch.
  public func read(frames range: Range<Int>) throws -> [Float] {
    guard range.lowerBound >= 0, range.upperBound <= frameCount else {
      throw DataStoreError.chunkRangeOutOfBounds(requested: range, available: frameCount)
    }
    guard !range.isEmpty else { return [] }

    file.framePosition = AVAudioFramePosition(range.lowerBound)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count))
    else {
      throw DataStoreError.invalidAudioFormat
    }
    try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))

    guard let channelData = buffer.floatChannelData else { return [] }
    let readCount = Int(buffer.frameLength)
    return Array(UnsafeBufferPointer(start: channelData[0], count: readCount))
  }

  /// Default ``ChunkFileReaderFactory`` production code uses.
  public static func make(url: URL) throws -> any ChunkFileReading {
    try AVFoundationChunkFileReader(url: url)
  }
}
