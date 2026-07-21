import AVFoundation

/// Mutable state `AVAudioConverter`'s `@Sendable` input block needs to hand
/// back the same input buffer exactly once. A tiny `@unchecked Sendable`
/// class, not a captured `var`: the input block's closure type is
/// `@Sendable`, so the compiler requires captured state to be `Sendable`
/// itself rather than a plain mutable local -- this is called synchronously
/// and exclusively within a single converter call (``ChunkResampler/resample(_:)``
/// or ``AdaptiveResampler/normalize(_:)``), never actually shared across
/// threads, so `@unchecked` is safe here. `internal` (not `private`) so
/// ``AdaptiveResampler`` shares this one input-block shim.
final class ConversionInputState: @unchecked Sendable {
  var provided = false
  let inputBuffer: AVAudioPCMBuffer

  init(inputBuffer: AVAudioPCMBuffer) {
    self.inputBuffer = inputBuffer
  }
}

/// Resamples mono `Float32` PCM from a source's native rate down to the
/// derived ASR rate (`docs/data-formats.md`'s "Dual-rate audio storage":
/// "The 16 kHz feed is derived from the native-rate copy"), via
/// `AVAudioConverter`.
///
/// A `final class` (not a `struct`) so the underlying `AVAudioConverter` is
/// created once per ``ChunkEncoder`` chunk and reused across the buffers
/// within that chunk, rather than rebuilt per call. `AVAudioConverter` isn't
/// documented `Sendable`; like ``AVFoundationChunkFileWriter``, this type is
/// only ever touched from within a single ``ChunkEncoder`` actor's
/// isolation, so `@unchecked Sendable` is safe -- the same thin-shim
/// exception.
public final class ChunkResampler: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let nativeFormat: AVAudioFormat
  private let asrFormat: AVAudioFormat

  /// - Returns: `nil` if either sample rate is non-positive, or the
  ///   native/ASR sample rates can't form a valid mono `Float32`
  ///   `AVAudioFormat` pair, or no converter can bridge them.
  ///   `AVAudioFormat` itself doesn't reject a non-positive sample rate at
  ///   construction time, so that case is checked explicitly rather than
  ///   relying on it to fail downstream.
  public init?(nativeSampleRate: Int, asrSampleRate: Int) {
    guard nativeSampleRate > 0, asrSampleRate > 0 else { return nil }
    guard
      let nativeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(nativeSampleRate), channels: 1,
        interleaved: false),
      let asrFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(asrSampleRate), channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: nativeFormat, to: asrFormat)
    else {
      return nil
    }
    self.nativeFormat = nativeFormat
    self.asrFormat = asrFormat
    self.converter = converter
  }

  /// Resamples one buffer's worth of native-rate samples to the ASR rate.
  /// Each call is an independent conversion of exactly the samples handed
  /// in (no cross-call buffering) -- a deliberate simplification for Phase
  /// 1: per-buffer independence keeps the failure/partial-write story
  /// simple (a failure on one buffer can't corrupt another's already-
  /// converted output), at the cost of a few samples of filter-state reset
  /// at each buffer boundary, which is inaudible at typical capture-buffer
  /// sizes.
  public func resample(_ samples: [Float]) throws -> [Float] {
    guard !samples.isEmpty else { return [] }
    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else {
      throw DataStoreError.invalidAudioFormat
    }
    inputBuffer.frameLength = AVAudioFrameCount(samples.count)
    let inputChannelData = inputBuffer.floatChannelData![0]
    samples.withUnsafeBufferPointer { source in
      inputChannelData.update(from: source.baseAddress!, count: samples.count)
    }

    let ratio = asrFormat.sampleRate / nativeFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 16
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: asrFormat, frameCapacity: outputCapacity)
    else {
      throw DataStoreError.invalidAudioFormat
    }

    let state = ConversionInputState(inputBuffer: inputBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      if state.provided {
        outStatus.pointee = .noDataNow
        return nil
      }
      state.provided = true
      outStatus.pointee = .haveData
      return state.inputBuffer
    }

    if let conversionError {
      throw conversionError
    }
    guard status != .error else {
      throw DataStoreError.resampleFailed
    }

    let outputChannelData = outputBuffer.floatChannelData![0]
    return Array(
      UnsafeBufferPointer(start: outputChannelData, count: Int(outputBuffer.frameLength)))
  }
}
