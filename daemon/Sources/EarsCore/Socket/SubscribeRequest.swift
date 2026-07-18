/// The pub/sub subscription request, matching
/// `docs/specs/capture-daemon.md`'s literal "Live feed" example:
///
/// ```jsonc
/// {"cmd":"subscribe","events":["vad","session","segment"],"sources":["mic","app:us.zoom.xos"]}
/// ```
///
/// Kept separate from ``ControlRequest`` because `subscribe` is not one of
/// the fourteen rows in the spec's command table — it transitions the
/// connection into an event stream of ``EarsEvent``s rather than getting a
/// single ``ControlResponse`` — but it's still a `cmd`-tagged request worth
/// modelling from the same literal example ``ControlRequest`` covers the
/// rest of the protocol from.
public struct SubscribeRequest: Sendable, Hashable {
  public var events: [EventKind]
  public var sources: [SourceID]

  public init(events: [EventKind], sources: [SourceID]) {
    self.events = events
    self.sources = sources
  }
}

extension SubscribeRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case cmd, events, sources
  }

  private enum Tag: String, Codable {
    case subscribe
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    _ = try container.decode(Tag.self, forKey: .cmd)
    events = try container.decode([EventKind].self, forKey: .events)
    sources = try container.decode([SourceID].self, forKey: .sources)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Tag.subscribe, forKey: .cmd)
    try container.encode(events, forKey: .events)
    try container.encode(sources, forKey: .sources)
  }
}
