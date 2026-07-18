import EarsCore

/// The signature event-producing actors (``CaptureActor``, ``SessionRegistry``)
/// publish live-feed ``EarsEvent``s through — a closure seam (like
/// ``SessionRegistry``'s `knownSourceIDs`) rather than a protocol, so producers
/// never learn what fan-out sits behind it and tests can record published
/// events with a plain closure.
public typealias EventSink = @Sendable (EarsEvent) async -> Void

/// The late-binding bridge between event producers and the control socket's
/// pub/sub fan-out (`EarsIPC.ControlSocketServer.publish(_:)`).
///
/// ## Why a bridge exists at all
///
/// The producers and the consumer of live-feed events have mismatched
/// lifetimes inside ``EarsDaemon``: every ``CaptureActor`` is built in
/// `init()`, but the `ControlSocketServer` only exists once `start()` binds
/// the listener — and `stop()` tears it down again while the capture actors
/// are still draining. Handing producers the server directly is therefore
/// impossible at construction time; handing them this bus (whose `publish`
/// they can call from day one) and attaching the server's `publish` once it
/// exists is the wiring seam.
///
/// ## Drop-when-unattached semantics
///
/// Live-feed events are ephemeral by design — the durable record is
/// `index.jsonl` / `session.toml`, and a subscriber that connects late never
/// expects a replay (see `docs/architecture.md`'s "the socket is for control
/// and ingestion only — results always land on disk"). So an event published
/// while no sink is attached (during startup, or after ``detach()`` mid-
/// shutdown) is silently dropped, not buffered.
public actor EventBus {
  private var sink: EventSink?

  public init() {}

  /// Start forwarding published events to `sink` (the socket server's
  /// `publish`, in real wiring). Replaces any previously attached sink.
  public func attach(_ sink: @escaping EventSink) {
    self.sink = sink
  }

  /// Stop forwarding; subsequently published events are dropped. Called
  /// before the socket server is shut down so no publish races its teardown.
  public func detach() {
    sink = nil
  }

  /// Forward `event` to the attached sink, or drop it if none is attached
  /// (see the type doc's drop-when-unattached note).
  public func publish(_ event: EarsEvent) async {
    await sink?(event)
  }
}
