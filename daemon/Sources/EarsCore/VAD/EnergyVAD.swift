/// A ``VAD`` conformance that classifies speech by short-frame RMS energy
/// against a fixed threshold.
///
/// This is a deliberate Phase 1 scoping decision: `docs/specs/capture-daemon.md`
/// calls out a Silero-class model as the default backend, but that's ANE-model
/// work for a later phase. `EnergyVAD` is a pure, dependency-free drop-in that
/// exercises the same ``VAD`` seam and the `speech_pad_ms` / `min_silence_ms`
/// semantics from `docs/configuration.md`'s `[earsd.vad]` table today, with no
/// model loading and no I/O.
///
/// - RMS, not peak: energy is the root-mean-square of each analysis frame, the
///   standard speech-energy measure. Peak amplitude lets one loud sample (a
///   click, a bit of quantization noise) spike a frame that has no sustained
///   speech energy; RMS reflects the frame's average power instead, which
///   tracks perceived loudness — and sustained voiced speech — much better.
/// - Analysis frames default to 20 ms, a conventional speech-VAD frame size
///   (in the range WebRTC's and Silero's own framing use) that's short enough
///   to localize speech onsets/offsets without being so short that per-frame
///   energy is dominated by noise.
/// - `minSilenceMs` ("gap before declaring silence" per the config doc) is
///   applied to the *raw* frame classification, before padding: a silence run
///   shorter than this doesn't split a speech region — the two raw runs it
///   separates are merged into one span.
/// - `speechPadMs` ("pad around detected speech spans") is applied last, once
///   per edge of each merged span, clamped to `[0, audio.duration]` so padding
///   never produces a span outside the buffer. Padding can bring two spans
///   into contact or overlap (e.g. a merge that only just missed the
///   min-silence floor); those are merged again as a final pass.
///
/// All arithmetic derives from the buffer's own sample count and sample rate
/// — no wall-clock reads, no shared mutable state, safe to call from any
/// isolation.
public struct EnergyVAD: VAD {
  /// RMS threshold (in the same `[-1, 1]` normalized units as
  /// ``AudioBuffer/samples``) above which a frame is classified as speech.
  ///
  /// `0.02` sits comfortably above quiet-room noise floor / quantization
  /// hiss and comfortably below typical voiced-speech RMS (roughly 0.05-0.3
  /// for normalized speech audio), while remaining conservative enough not
  /// to miss quieter speech. Callers with a noisier capture path should
  /// raise it.
  public var energyThreshold: Float

  /// Length of each energy-analysis frame, in milliseconds.
  public var analysisFrameMs: Double

  /// Padding applied to both edges of each detected speech span, in
  /// milliseconds. Mirrors `[earsd.vad].speech_pad_ms`.
  public var speechPadMs: Double

  /// Minimum silence duration, in milliseconds, before a gap between two
  /// speech runs is treated as splitting them rather than being merged
  /// across. Mirrors `[earsd.vad].min_silence_ms`.
  public var minSilenceMs: Double

  public init(
    energyThreshold: Float = 0.02,
    analysisFrameMs: Double = 20,
    speechPadMs: Double = 300,
    minSilenceMs: Double = 700
  ) {
    self.energyThreshold = energyThreshold
    self.analysisFrameMs = analysisFrameMs
    self.speechPadMs = speechPadMs
    self.minSilenceMs = minSilenceMs
  }

  public func detect(in audio: AudioBuffer) throws -> [VADSpan] {
    guard audio.sampleRate > 0, !audio.samples.isEmpty else { return [] }

    let frameSize = max(1, Int(Double(audio.sampleRate) * analysisFrameMs / 1000))
    let flags = speechFlags(for: audio.samples, frameSize: frameSize)
    let rawSpans = rawSpeechSpans(
      from: flags, frameSize: frameSize, sampleRate: audio.sampleRate,
      totalSamples: audio.samples.count)
    guard !rawSpans.isEmpty else { return [] }

    let merged = mergingShortSilences(rawSpans)
    let padded = padding(merged, duration: audio.duration)

    return padded.map { VADSpan(state: .speech, start: $0.start, end: $0.end) }
  }

  // MARK: - Frame classification

  private func speechFlags(for samples: [Float], frameSize: Int) -> [Bool] {
    var flags: [Bool] = []
    flags.reserveCapacity((samples.count + frameSize - 1) / frameSize)
    var index = 0
    while index < samples.count {
      let end = min(index + frameSize, samples.count)
      flags.append(Self.rms(samples[index..<end]) > energyThreshold)
      index = end
    }
    return flags
  }

  private static func rms(_ frame: ArraySlice<Float>) -> Float {
    guard !frame.isEmpty else { return 0 }
    let sumOfSquares = frame.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumOfSquares / Float(frame.count)).squareRoot()
  }

  // MARK: - Raw span extraction

  private func rawSpeechSpans(
    from flags: [Bool],
    frameSize: Int,
    sampleRate: Int,
    totalSamples: Int
  ) -> [(start: Double, end: Double)] {
    var spans: [(start: Double, end: Double)] = []
    var runStart: Int?
    for (i, isSpeech) in flags.enumerated() {
      if isSpeech {
        if runStart == nil { runStart = i }
      } else if let start = runStart {
        spans.append(
          seconds(
            start, i, frameSize: frameSize, sampleRate: sampleRate, totalSamples: totalSamples)
        )
        runStart = nil
      }
    }
    if let start = runStart {
      spans.append(
        seconds(
          start, flags.count, frameSize: frameSize, sampleRate: sampleRate,
          totalSamples: totalSamples))
    }
    return spans
  }

  private func seconds(
    _ startFrame: Int,
    _ endFrame: Int,
    frameSize: Int,
    sampleRate: Int,
    totalSamples: Int
  ) -> (start: Double, end: Double) {
    let startSample = min(startFrame * frameSize, totalSamples)
    let endSample = min(endFrame * frameSize, totalSamples)
    return (Double(startSample) / Double(sampleRate), Double(endSample) / Double(sampleRate))
  }

  // MARK: - min_silence_ms merge

  private func mergingShortSilences(
    _ spans: [(start: Double, end: Double)]
  ) -> [(start: Double, end: Double)] {
    var merged: [(start: Double, end: Double)] = [spans[0]]
    let minSilenceSeconds = minSilenceMs / 1000
    for span in spans.dropFirst() {
      let last = merged[merged.count - 1]
      if span.start - last.end < minSilenceSeconds {
        merged[merged.count - 1].end = span.end
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  // MARK: - speech_pad_ms padding

  private func padding(
    _ spans: [(start: Double, end: Double)],
    duration: Double
  ) -> [(start: Double, end: Double)] {
    let padSeconds = speechPadMs / 1000
    let padded = spans.map {
      (start: max(0, $0.start - padSeconds), end: min(duration, $0.end + padSeconds))
    }

    var result: [(start: Double, end: Double)] = [padded[0]]
    for span in padded.dropFirst() {
      if span.start <= result[result.count - 1].end {
        result[result.count - 1].end = max(result[result.count - 1].end, span.end)
      } else {
        result.append(span)
      }
    }
    return result
  }
}
