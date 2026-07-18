import EarsCore

/// A ``CaptureBackend`` that emits a scripted sequence of ``AudioBuffer``s and
/// then finishes, so tests can drive capture-consuming code (a future
/// `CaptureActor`, session/index wiring) deterministically with no Core Audio,
/// no device, and no permission.
///
/// Distinct from ``NullCaptureBackend`` (which emits nothing) and from the real
/// `AVAudioEngine`-driven synthetic *source node* used inside `EarsCaptureKit`'s
/// own integration tests: this one is pure and needs no AVFoundation, so it lives
/// here for any target to reuse. Test scaffolding, not shipped capability.
public struct SyntheticCaptureBackend: CaptureBackend {
  public let source: SourceID
  private let buffers: [AudioBuffer]

  public init(source: SourceID = "mic", buffers: [AudioBuffer]) {
    self.source = source
    self.buffers = buffers
  }

  /// Convenience: a single mono buffer of `sampleCount` samples at `value`.
  public init(
    source: SourceID = "mic",
    sampleCount: Int,
    value: Float = 0.5,
    sampleRate: Int = 48_000
  ) {
    self.init(
      source: source,
      buffers: [
        AudioBuffer(samples: Array(repeating: value, count: sampleCount), sampleRate: sampleRate)
      ]
    )
  }

  public func start() async throws -> AsyncStream<AudioBuffer> {
    let buffers = self.buffers
    return AsyncStream { continuation in
      for buffer in buffers {
        continuation.yield(buffer)
      }
      continuation.finish()
    }
  }

  public func stop() async {}
}
