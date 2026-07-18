import EarsCore

/// A ``CaptureBackend`` fed by explicit ``push(_:)`` calls instead of
/// pulling from real hardware — the "ingest push direction for socket-fed
/// sources" `CaptureBackend`'s own doc comment defers to Phase 6. One
/// instance per dynamically-created `browser:<label>` source; ``EarsDaemon``
/// owns its lifetime alongside the ``CaptureActor`` it backs.
///
/// An `actor` so concurrent ``push(_:)`` calls from the ingest WebSocket's
/// per-connection read loop can never race the stream's lifecycle.
public actor PushCaptureBackend: CaptureBackend {
  public nonisolated let source: SourceID
  private var continuation: AsyncStream<AudioBuffer>.Continuation?

  public init(source: SourceID) {
    self.source = source
  }

  public func start() async throws -> AsyncStream<AudioBuffer> {
    let (stream, continuation) = AsyncStream<AudioBuffer>.makeStream()
    self.continuation = continuation
    return stream
  }

  public func stop() async {
    continuation?.finish()
    continuation = nil
  }

  /// Feed one decoded buffer in. A no-op before ``start()``/after
  /// ``stop()`` — the buffer is simply dropped, matching a real backend
  /// producing nothing while not capturing.
  public func push(_ buffer: AudioBuffer) {
    continuation?.yield(buffer)
  }
}
