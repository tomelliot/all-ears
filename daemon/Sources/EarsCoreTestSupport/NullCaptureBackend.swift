import EarsCore

/// A ``CaptureBackend`` that produces no audio: `start()` returns an immediately
/// finished stream. Proves the seam is mockable and `Sendable`-clean; not shipped
/// capability.
public struct NullCaptureBackend: CaptureBackend {
  public let source: SourceID

  public init(source: SourceID = "mic") {
    self.source = source
  }

  public func start() async throws -> AsyncStream<AudioBuffer> {
    AsyncStream { $0.finish() }
  }

  public func stop() async {}
}
