import EarsCore

extension EarsEvent {
  /// The ``EventKind`` this event is discriminated as on the wire — the value
  /// a ``SubscribeRequest/events`` list is matched against.
  public var kind: EventKind {
    switch self {
    case .vad: .vad
    case .session: .session
    case .segment: .segment
    }
  }

  /// The ``SourceID`` this event pertains to, when it has one. Only `vad`
  /// events carry a source; `session` and `segment` are keyed by session id
  /// and are considered sourceless for subscription filtering.
  public var source: SourceID? {
    switch self {
    case .vad(let source, _, _): source
    case .session, .segment: nil
    }
  }
}

/// Decides whether a published ``EarsEvent`` should be delivered to a given
/// ``SubscribeRequest`` subscription — the pub/sub fan-out filter, factored
/// out as pure logic so it is unit-tested tier-0 (no sockets, no actors) and
/// reused unchanged by ``ControlSocketServer``'s fan-out.
///
/// Semantics, matching the spec's `subscribe` example
/// (`{"events":[...],"sources":[...]}`):
/// - An empty `events` list matches every kind; a non-empty list matches only
///   the listed kinds.
/// - An empty `sources` list matches every source. A non-empty list excludes a
///   *sourced* event whose source isn't listed, but always passes *sourceless*
///   events (`session`, `segment`) — a source filter constrains which sources'
///   VAD you see without silently dropping session/segment activity the
///   subscriber also asked for by kind.
public enum EventFilter {
  public static func matches(_ event: EarsEvent, _ subscription: SubscribeRequest) -> Bool {
    if !subscription.events.isEmpty && !subscription.events.contains(event.kind) {
      return false
    }
    if subscription.sources.isEmpty { return true }
    guard let source = event.source else { return true }
    return subscription.sources.contains(source)
  }
}
