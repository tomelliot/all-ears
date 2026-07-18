/// The capture seam: one backend captures one source into a stream of mono PCM
/// buffers, which `earsd`'s per-source worker drains to encode and write chunks.
///
/// - Design rationale (no Swift signature exists in the docs; shaped from
///   `docs/specs/capture-daemon.md` + `docs/architecture.md`): the daemon opens a
///   capture engine per enabled source and hands the realtime samples off to a
///   worker via a lock-free ring. Modelled minimally as "start → get an
///   `AsyncStream` of buffers, stop → tear down", which is the smallest seam that
///   (a) keeps the syscall-heavy engine behind a mockable protocol, (b) is
///   `Sendable` and free of `@MainActor`, and (c) lets a `CaptureActor` own the
///   lifecycle. ``source`` is exposed so a manager can label and route buffers
///   without a side channel. The buffer type is compatible with what will flow
///   over the control socket's ingest path (`ingest.open` declares a format;
///   pushed frames become buffers for a `browser:<label>` source).
///
/// - Phase 1 (`EarsCaptureKit.MicCaptureBackend`, wired into a real running
///   `earsd`) proved this shape unchanged: ``source``/``start()``/``stop()``
///   are still the whole protocol. The concerns this doc comment once
///   expected might force new members here didn't -- they were resolved
///   without touching this protocol instead. The dropped-sample counter and
///   fail-loud-under-backpressure policy live behind a separate, optional
///   `EarsCaptureKit.CaptureStatsReporting` conformance a caller may downcast
///   to (see `CaptureActor.status()`'s doc comment); default-device-change
///   recovery is handled entirely inside `MicCaptureBackend` itself,
///   invisible at this seam. Format negotiation (a system-audio tap's true
///   format read from `kAudioTapPropertyFormat`) and the ingest *push*
///   direction for socket-fed sources remain genuinely deferred, to Phase 4
///   and Phase 6 respectively -- not yet built, not this phase's scope.
public protocol CaptureBackend: Sendable {
  /// The stable id of the source this backend captures.
  var source: SourceID { get }

  /// Begin capturing. Delivers mono PCM buffers until the stream finishes
  /// (on ``stop()`` or unrecoverable failure).
  func start() async throws -> AsyncStream<AudioBuffer>

  /// Stop capturing and release the underlying engine/tap; finishes the stream.
  func stop() async
}
