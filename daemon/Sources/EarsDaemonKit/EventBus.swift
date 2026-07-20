import EarsCore

/// The signature event-producing actors (``CaptureActor``, ``SessionRegistry``,
/// ``MeetingRegistry``) publish live-feed ``EarsEvent``s through — a closure
/// seam rather than a protocol, so producers never learn what fan-out sits
/// behind it and tests can record published events with a plain closure.
public typealias EventSink = @Sendable (EarsEvent) async -> Void

/// The late-binding bridge between event producers and the control
/// transports' fan-out — and, in v2, the owner of the **monotonic state
/// revision** every state notification and `subscribe` snapshot carries
/// (`docs/product/specs/control-protocol.md`'s "State sync").
///
/// ## Revisions
///
/// State events (`meeting`, `session`, `source` — ``EventKind/isState``) each
/// increment ``currentRev()`` by exactly one and are delivered tagged with
/// their revision; telemetry events (`vad`, `segment`, `job`) are delivered
/// untagged and never touch the counter. Because assignment and enqueue
/// happen synchronously inside this actor, and a single drain task forwards
/// frames to the attached sink in enqueue order, subscribers observe state
/// revisions contiguously — which is exactly the invariant the client-side
/// "apply iff `rev == last_rev + 1`" rule depends on. Revisions are scoped to
/// one daemon boot (see `hello`'s `boot_id`).
///
/// ## Drop-when-unattached semantics
///
/// Live-feed events are ephemeral by design — the durable record is on disk
/// — so an event published while no sink is attached is dropped, not
/// buffered. The revision counter still advances for dropped *state* events:
/// a late subscriber's snapshot simply starts at the current revision.
public actor EventBus {
  /// What ``attach(_:)`` receives: fully-formed, revision-tagged frames.
  public typealias FrameSink = @Sendable (EventFrame) async -> Void

  private var frames: AsyncStream<EventFrame>.Continuation?
  private var drainTask: Task<Void, Never>?
  private var rev = 0

  public init() {}

  /// Start forwarding published frames to `sink` (the transports' fan-out,
  /// in real wiring). Replaces any previously attached sink.
  public func attach(_ sink: @escaping FrameSink) {
    detachDelivery()
    // Bounded like the per-connection outbound queues: a stalled sink drops
    // the oldest frames (loudly at the connection layer) instead of growing
    // without bound. A dropped state frame surfaces to subscribers as a rev
    // gap, and the documented recovery is resubscribe-for-snapshot.
    let (stream, continuation) = AsyncStream.makeStream(
      of: EventFrame.self, bufferingPolicy: .bufferingNewest(256))
    frames = continuation
    drainTask = Task {
      for await frame in stream {
        await sink(frame)
      }
    }
  }

  /// Stop forwarding; subsequently published events are dropped. Called
  /// before the servers are shut down so no publish races their teardown.
  public func detach() {
    detachDelivery()
  }

  private func detachDelivery() {
    frames?.finish()
    frames = nil
    drainTask?.cancel()
    drainTask = nil
  }

  /// The current state revision — what a `subscribe` snapshot is tagged
  /// with. Read *before* gathering snapshot state (see `SnapshotData`).
  public func currentRev() -> Int {
    rev
  }

  /// Publish one event, classing it by kind: state events get the next
  /// revision, telemetry events go out untagged. Returns the assigned
  /// revision for state events.
  @discardableResult
  public func publish(_ event: EarsEvent) -> Int? {
    guard event.kind.isState else {
      frames?.yield(EventFrame(event: event, rev: nil))
      return nil
    }
    return publishState { _ in event }
  }

  /// Publish a state event whose payload needs to *embed* its own revision
  /// (a `Meeting`'s `rev` field): `make` receives the assigned revision and
  /// returns the event to deliver. Assignment and enqueue are atomic within
  /// this actor, so revisions reach subscribers in order and gap-free.
  @discardableResult
  public func publishState(_ make: (Int) -> EarsEvent) -> Int {
    rev += 1
    frames?.yield(EventFrame(event: make(rev), rev: rev))
    return rev
  }
}
