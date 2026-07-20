import EarsCore

/// Decides whether a published ``EventFrame`` should be delivered to a given
/// subscription — the fan-out filter, factored out as pure logic so it is
/// unit-tested tier-0 (no sockets, no actors) and reused unchanged by both
/// control transports.
///
/// Semantics (`docs/product/specs/control-protocol.md`'s "State sync"):
/// - **State frames** (`meeting`, `session`, `source`) are always delivered
///   to every subscriber — unconditional delivery is what keeps `rev`
///   contiguous — so neither filter list applies to them.
/// - **Telemetry frames** (`vad`, `segment`, `job`) pass the `events` filter
///   (empty matches every kind) and, for *sourced* telemetry (`vad`), the
///   `sources` filter (empty matches every source; sourceless telemetry
///   always passes it).
public enum EventFilter {
  public static func matches(_ frame: EventFrame, _ subscription: SubscribeParams) -> Bool {
    let event = frame.event
    if event.kind.isState { return true }
    if !subscription.events.isEmpty && !subscription.events.contains(event.kind) {
      return false
    }
    if subscription.sources.isEmpty { return true }
    guard let source = event.filterSource else { return true }
    return subscription.sources.contains(source)
  }
}
