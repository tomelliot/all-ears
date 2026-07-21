import AVFoundation
import EarsCore

// `import AVFoundation` transitively surfaces CoreAudio's C `AudioBuffer`
// struct, which collides with EarsCore's `AudioBuffer` model. A scoped import
// of the model takes precedence over the wildcard AVFoundation import, so an
// unqualified `AudioBuffer` in this file resolves to ours. (`EarsCore.AudioBuffer`
// can't disambiguate here — the module also declares an `enum EarsCore` that
// shadows the module name.)
import struct EarsCore.AudioBuffer

/// Normalizes mono `Float32` PCM buffers of *any* input rate to one fixed
/// target rate — the seam that makes the capture path survive an input
/// device's sample rate changing mid-run (a Bluetooth headset at 16 kHz
/// replacing the built-in 48 kHz mic). Backends stamp buffers with whatever
/// rate the device actually delivers; `CaptureActor` runs every buffer
/// through this before VAD/encode so the rest of the pipeline keeps its
/// one-rate-per-source invariant (and `ChunkEncoder.sampleRateMismatch`
/// stays a never-hit backstop).
///
/// Unlike ``ChunkResampler`` (fixed native→ASR ratio, converter per chunk,
/// per-call independence), this converter is **persistent across same-rate
/// buffers and primed with `.none`** — deliberately. It sits on the
/// continuous capture path where every output frame becomes timeline:
/// default priming can shave a few frames per convert call, which at
/// capture-buffer cadence compounds into real playhead-vs-wall-clock drift.
/// `.none` priming plus a reused converter keeps output frame counts at the
/// exact rational ratio (±1 rounding, non-accumulating). The converter is
/// lazily rebuilt only when the input rate actually changes.
///
/// `@unchecked Sendable` under the same thin-shim exception as
/// ``ChunkResampler``: `AVAudioConverter` isn't documented `Sendable`, and
/// this instance is only ever touched from within a single `CaptureActor`'s
/// isolation.
public final class AdaptiveResampler: @unchecked Sendable {
  public let targetSampleRate: Int

  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var currentInputRate: Int?

  /// - Returns: `nil` if the target rate is non-positive or can't form a
  ///   valid mono `Float32` `AVAudioFormat` (`AVAudioFormat` doesn't reject
  ///   a non-positive rate itself, so it's checked explicitly).
  public init?(targetSampleRate: Int) {
    guard targetSampleRate > 0,
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSampleRate), channels: 1,
        interleaved: false)
    else { return nil }
    self.targetSampleRate = targetSampleRate
    self.targetFormat = targetFormat
  }

  /// Returns `buffer` untouched when it is already at the target rate;
  /// otherwise resamples it and restamps it with ``targetSampleRate``.
  ///
  /// - Throws: `DataStoreError.invalidAudioFormat` for an input rate no
  ///   converter can bridge (non-positive, or `AVAudioConverter` refuses
  ///   the pair); `DataStoreError.resampleFailed` (or the converter's own
  ///   `NSError`) when a conversion fails.
  public func normalize(_ buffer: AudioBuffer) throws -> AudioBuffer {
    if buffer.sampleRate == targetSampleRate { return buffer }
    if buffer.samples.isEmpty {
      return AudioBuffer(samples: [], sampleRate: targetSampleRate)
    }

    if buffer.sampleRate != currentInputRate {
      try rebuildConverter(inputRate: buffer.sampleRate)
    }
    guard let converter, let inputFormat else {
      throw DataStoreError.invalidAudioFormat
    }

    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(buffer.samples.count))
    else {
      throw DataStoreError.invalidAudioFormat
    }
    inputBuffer.frameLength = AVAudioFrameCount(buffer.samples.count)
    let inputChannelData = inputBuffer.floatChannelData![0]
    buffer.samples.withUnsafeBufferPointer { source in
      inputChannelData.update(from: source.baseAddress!, count: buffer.samples.count)
    }

    let ratio = targetFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(buffer.samples.count) * ratio) + 16
    guard
      let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)
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
    let converted = Array(
      UnsafeBufferPointer(start: outputChannelData, count: Int(outputBuffer.frameLength)))
    return AudioBuffer(samples: converted, sampleRate: targetSampleRate)
  }

  private func rebuildConverter(inputRate: Int) throws {
    converter = nil
    inputFormat = nil
    currentInputRate = nil
    guard inputRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate), channels: 1,
        interleaved: false),
      let built = AVAudioConverter(from: format, to: targetFormat)
    else {
      throw DataStoreError.invalidAudioFormat
    }
    built.primeMethod = .none
    converter = built
    inputFormat = format
    currentInputRate = inputRate
  }
}
