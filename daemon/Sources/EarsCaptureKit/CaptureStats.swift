import EarsCore

/// Observable health of a capture backend's realtime hand-off: the dropped-sample
/// counter and the unrecoverable-failure latch surfaced by ``AudioSampleRing``.
///
/// `docs/specs/capture-daemon.md` requires the dropped-sample counter to be
/// surfaced (for logs) and the stream to fail under sustained backpressure. The
/// Phase 0 ``CaptureBackend`` seam models only start/stop/source and deliberately
/// omitted this (its doc comment flags it as provisional). Rather than widen that
/// seam now, this is exposed as an additive, opt-in capability
/// (``CaptureStatsReporting``) — mirroring the codebase's capability-protocol
/// pattern (`StreamingTranscriber` et al.) — so existing conformances
/// (`NullCaptureBackend`) keep compiling untouched and a future `CaptureActor`
/// can depend on the capability where a backend offers it.
public struct CaptureStats: Sendable, Hashable {
  /// Cumulative samples dropped under backpressure since capture started.
  public var droppedSampleCount: Int
  /// `true` once the realtime ring latched unrecoverable failure and the stream
  /// finished as a result.
  public var hasFailed: Bool

  public init(droppedSampleCount: Int, hasFailed: Bool) {
    self.droppedSampleCount = droppedSampleCount
    self.hasFailed = hasFailed
  }
}

/// A ``CaptureBackend`` that also reports realtime-handoff health. Opt-in so the
/// base seam stays minimal.
public protocol CaptureStatsReporting: CaptureBackend {
  /// The current dropped-sample counter and failure latch.
  var stats: CaptureStats { get async }
}
