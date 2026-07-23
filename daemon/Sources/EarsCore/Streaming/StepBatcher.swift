/// Fixed-cadence batcher for streaming decode: accumulates arbitrarily-sized
/// incoming audio buffers and releases fixed-size model steps, decoupling
/// chunk-arrival cadence (30 s capture chunks, bursty ingest pushes) from
/// the model's per-step compute budget — the `StepBatcher` role named in
/// `docs/specs/transcribe.md`'s append-only delta contract.
///
/// Pure accumulation logic, no I/O and no clock — tier-0 tested per
/// `docs/engineering-practices.md`. The *caller* decides when to stop and
/// ``flush()`` the sub-step remainder (end of stream, forced finalization);
/// this type never emits a short step on its own, so every buffer it returns
/// from ``append(_:)`` is exactly ``stepFrameCount`` frames.
public struct StepBatcher: Sendable, Hashable {
  /// The fixed step size, in frames (samples, since audio is mono).
  public let stepFrameCount: Int

  private var pending: [Float] = []
  private var sampleRate: Int?

  /// - Parameter stepFrameCount: Frames per released step; must be positive.
  ///   Tune to the per-step compute budget (e.g. 2 s at 16 kHz = 32 000).
  public init(stepFrameCount: Int) {
    precondition(stepFrameCount > 0, "StepBatcher requires a positive step size")
    self.stepFrameCount = stepFrameCount
  }

  /// Frames accumulated but not yet released as a full step.
  public var pendingFrameCount: Int { pending.count }

  /// Accumulates `buffer` and returns every full step now available, in
  /// order — zero or more ``AudioBuffer``s of exactly ``stepFrameCount``
  /// frames each. All appended buffers must share one sample rate (a single
  /// source's ASR feed is constant-rate); mixing rates is a caller bug and
  /// traps rather than silently resampling or mislabelling.
  public mutating func append(_ buffer: AudioBuffer) -> [AudioBuffer] {
    guard buffer.frameCount > 0 else { return [] }
    if let sampleRate {
      precondition(
        sampleRate == buffer.sampleRate,
        "StepBatcher fed mixed sample rates (\(sampleRate) then \(buffer.sampleRate))")
    } else {
      sampleRate = buffer.sampleRate
    }

    pending.append(contentsOf: buffer.samples)
    var steps: [AudioBuffer] = []
    while pending.count >= stepFrameCount {
      steps.append(
        AudioBuffer(samples: Array(pending.prefix(stepFrameCount)), sampleRate: buffer.sampleRate))
      pending.removeFirst(stepFrameCount)
    }
    return steps
  }

  /// Releases the sub-step remainder (shorter than ``stepFrameCount``) as a
  /// final short buffer, or `nil` if nothing is pending. Call at end of
  /// stream or at a forced finalization boundary.
  public mutating func flush() -> AudioBuffer? {
    guard let sampleRate, !pending.isEmpty else { return nil }
    defer { pending = [] }
    return AudioBuffer(samples: pending, sampleRate: sampleRate)
  }
}
