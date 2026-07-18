import AVFoundation
import Foundation

/// The real ``ChunkFileWriting`` conformance: writes mono `Float32` samples
/// through a real `AVAudioFile`, encoding to the container/codec described
/// by ``ChunkAudioSettings``.
///
/// A `final class` (not a `struct`) because ``finish()`` needs to release
/// the `AVAudioFile` explicitly (dropping the last reference is what
/// finalizes the container's atoms) rather than relying on a struct copy's
/// implicit deinit timing. `AVAudioFile` itself isn't documented `Sendable`;
/// this type is used exclusively from within a single ``ChunkEncoder``
/// actor's isolation, one writer per open chunk, never shared across
/// concurrent callers, so `@unchecked Sendable` is safe here -- exactly the
/// "thin shim behind a protocol" exception `docs/architecture.md` allows.
public final class AVFoundationChunkFileWriter: ChunkFileWriting, @unchecked Sendable {
  private var file: AVAudioFile?
  private let format: AVAudioFormat

  public init(url: URL, settings: ChunkAudioSettings) throws {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: settings.sampleRate, channels: 1,
        interleaved: false)
    else {
      throw DataStoreError.invalidAudioFormat
    }
    self.format = format
    self.file = try AVAudioFile(
      forWriting: url, settings: settings.foundationSettings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
  }

  public func write(samples: [Float]) throws {
    guard let file else { throw DataStoreError.writerClosed }
    guard !samples.isEmpty else { return }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else {
      throw DataStoreError.invalidAudioFormat
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channelData = buffer.floatChannelData![0]
    samples.withUnsafeBufferPointer { source in
      channelData.update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
  }

  public func finish() throws {
    // Dropping the last reference finalizes AVAudioFile's container atoms.
    // AtomicFileIO fsyncs the path immediately after this returns, so the
    // bytes are durable before the temp-to-final rename.
    file = nil
  }

  /// Default ``ChunkFileWriterFactory`` production code uses.
  public static func make(url: URL, settings: ChunkAudioSettings) throws -> any ChunkFileWriting {
    try AVFoundationChunkFileWriter(url: url, settings: settings)
  }
}
