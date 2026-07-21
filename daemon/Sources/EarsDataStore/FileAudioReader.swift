import AVFoundation
import EarsCore

// `import AVFoundation` transitively surfaces CoreAudio's C `AudioBuffer`
// struct, which collides with EarsCore's `AudioBuffer` model. A scoped import
// of the model takes precedence over the wildcard AVFoundation import, so an
// unqualified `AudioBuffer` in this file resolves to ours -- the same
// disambiguation ``AdaptiveResampler`` documents.
import struct EarsCore.AudioBuffer

/// Decodes a standalone on-disk audio file (any container `AVFoundation`
/// reads -- `.m4a`, `.wav`, `.caf`, ...) into ASR-ready ``AudioSlice``s: the
/// same currency ``SegmentedAudioReader`` hands a ``Transcriber``, so the
/// `transcribe` pipeline runs a file through the *identical* model seam it
/// runs ring-buffer audio through.
///
/// The file-input sibling of ``SegmentedAudioReader``. Where that reader
/// reconstructs slices from a source's `asr/` chunks plus its VAD `index.jsonl`
/// (silence-skipping, natural-pause segmentation), this reader has neither an
/// index nor VAD, so it does the minimum an arbitrary file allows: decode the
/// whole file, down-mix to mono, resample to the ASR rate
/// (``AdaptiveResampler``), and return it as one slice. FluidAudio's batch
/// decode path chunks long audio internally with proper cross-window overlap,
/// so a single whole-file slice decodes better than the naive fixed-window
/// splits this layer -- lacking VAD to place cuts at real pauses -- could
/// otherwise make.
///
/// The `AVFoundation` decode is injected (``Decoder``) exactly like
/// ``SegmentedAudioReader``'s ``ChunkFileReaderFactory``, so the pure
/// resample-and-slice logic is unit-testable with a fake decoder and no real
/// audio file.
public struct FileAudioReader: Sendable {
  /// Decodes `url` into a native-rate, mono ``AudioBuffer``. The production
  /// default is ``decodeWithAVFoundation(_:)``; tests inject a fake.
  public typealias Decoder = @Sendable (URL) throws -> AudioBuffer

  private let decode: Decoder

  public init(decode: @escaping Decoder = FileAudioReader.decodeWithAVFoundation) {
    self.decode = decode
  }

  /// Decodes `fileURL`, resamples to `targetSampleRate`, and returns it as a
  /// single ``AudioSlice`` anchored at `anchor`.
  ///
  /// - Parameters:
  ///   - fileURL: The audio file to transcribe.
  ///   - targetSampleRate: The rate the ASR backend expects (16 kHz for
  ///     FluidAudio's Parakeet). The decoded buffer is resampled to this
  ///     before it reaches the model, since ``Transcriber`` implementations
  ///     assume their input is already at the model's rate.
  ///   - anchor: The wall-clock instant the slice's range starts at. A file
  ///     has no real capture time, so this is a synthetic zero point; the
  ///     caller places the ``Transcriber``'s slice-relative ``Segment``
  ///     offsets back onto its own timeline against the same anchor.
  /// - Returns: One slice covering `[anchor, anchor + duration)`, or an empty
  ///   array for an empty/silent file.
  /// - Throws: Whatever the ``Decoder`` throws (unreadable/unsupported file),
  ///   or ``DataStoreError/invalidAudioFormat`` if `targetSampleRate` can't
  ///   form a valid resampler.
  public func slices(
    fileURL: URL,
    targetSampleRate: Int = 16000,
    anchor: Instant = Instant(secondsSinceEpoch: 0)
  ) throws -> [AudioSlice] {
    let decoded = try decode(fileURL)
    guard !decoded.samples.isEmpty else { return [] }

    let resampled: AudioBuffer
    if decoded.sampleRate == targetSampleRate {
      resampled = decoded
    } else {
      guard let resampler = AdaptiveResampler(targetSampleRate: targetSampleRate) else {
        throw DataStoreError.invalidAudioFormat
      }
      resampled = try resampler.normalize(decoded)
    }
    guard !resampled.samples.isEmpty else { return [] }

    let range = TimeRange(start: anchor, end: anchor.advanced(by: resampled.duration))
    return [AudioSlice(audio: resampled, range: range)]
  }

  /// The production ``Decoder``: reads any `AVFoundation`-supported container
  /// into mono `Float32` PCM at the file's own sample rate. Multi-channel
  /// input is down-mixed by averaging channels (rather than dropping to the
  /// left channel) so a stereo recording keeps both sides. Requesting
  /// `commonFormat: .pcmFormatFloat32` makes `AVAudioFile` run the container's
  /// decoder internally, so this never touches compressed bytes -- the same
  /// approach as ``AVFoundationChunkFileReader``.
  public static func decodeWithAVFoundation(_ url: URL) throws -> AudioBuffer {
    let file = try AVAudioFile(
      forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let sampleRate = Int(file.processingFormat.sampleRate.rounded())
    let frameCount = Int(file.length)
    guard frameCount > 0 else { return AudioBuffer(samples: [], sampleRate: sampleRate) }

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else {
      throw DataStoreError.invalidAudioFormat
    }
    try file.read(into: buffer)

    guard let channelData = buffer.floatChannelData else {
      return AudioBuffer(samples: [], sampleRate: sampleRate)
    }
    let readCount = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)

    if channels <= 1 {
      let mono = Array(UnsafeBufferPointer(start: channelData[0], count: readCount))
      return AudioBuffer(samples: mono, sampleRate: sampleRate)
    }

    var mono = [Float](repeating: 0, count: readCount)
    for channel in 0..<channels {
      let pointer = channelData[channel]
      for frame in 0..<readCount { mono[frame] += pointer[frame] }
    }
    let scale = 1 / Float(channels)
    for frame in 0..<readCount { mono[frame] *= scale }
    return AudioBuffer(samples: mono, sampleRate: sampleRate)
  }
}
