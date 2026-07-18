/// The wire representation of a session in `session.list`'s response.
///
/// ``SessionDescriptor``'s own synthesized `Codable` renders `Instant`
/// fields as `Instant`'s plain-`Double`-seconds form (see that type's doc
/// comment) and uses Swift's camelCase property names verbatim
/// (`triggerDetail`, not `trigger_detail`) — the right shape for
/// `EarsConfig`'s TOML mapping, but not for the control socket, whose other
/// payloads (`status`, `vad`/`session` events, ...) render timestamps as
/// ISO-8601 and multi-word fields as `snake_case`, matching
/// `session.toml`'s own on-disk conventions (`docs/data-formats.md`).
///
/// `SessionSummary` carries the same fields as ``SessionDescriptor`` with
/// wire-appropriate `Codable`, mirroring the domain-type/wire-type split
/// this module already has between ``IndexedChunk`` and
/// `IndexEvent.chunk(start:end:file:frames:)` — a distinct wire shape for
/// the same concept, converted via ``init(_:)`` and ``descriptor``.
public struct SessionSummary: Sendable, Hashable {
  public var schema: Int
  public var id: String
  public var slug: String
  public var sources: [SourceID]
  public var start: Instant
  public var end: Instant?
  public var state: SessionState
  public var trigger: TriggerKind
  public var triggerDetail: String?
  public var vocab: String?

  public init(_ descriptor: SessionDescriptor) {
    schema = descriptor.schema
    id = descriptor.id
    slug = descriptor.slug
    sources = descriptor.sources
    start = descriptor.start
    end = descriptor.end
    state = descriptor.state
    trigger = descriptor.trigger
    triggerDetail = descriptor.triggerDetail
    vocab = descriptor.vocab
  }

  /// The underlying ``SessionDescriptor`` this wire shape represents.
  public var descriptor: SessionDescriptor {
    SessionDescriptor(
      schema: schema,
      id: id,
      slug: slug,
      sources: sources,
      start: start,
      end: end,
      state: state,
      trigger: trigger,
      triggerDetail: triggerDetail,
      vocab: vocab
    )
  }
}

extension SessionSummary: Codable {
  private enum CodingKeys: String, CodingKey {
    case schema, id, slug, sources, start, end, state, trigger, vocab
    case triggerDetail = "trigger_detail"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    id = try container.decode(String.self, forKey: .id)
    slug = try container.decode(String.self, forKey: .slug)
    sources = try container.decode([SourceID].self, forKey: .sources)
    start = try container.decodeISO8601Instant(forKey: .start)
    end = try container.decodeISO8601InstantIfPresent(forKey: .end)
    state = try container.decode(SessionState.self, forKey: .state)
    trigger = try container.decode(TriggerKind.self, forKey: .trigger)
    triggerDetail = try container.decodeIfPresent(String.self, forKey: .triggerDetail)
    vocab = try container.decodeIfPresent(String.self, forKey: .vocab)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(id, forKey: .id)
    try container.encode(slug, forKey: .slug)
    try container.encode(sources, forKey: .sources)
    try container.encodeISO8601Instant(start, forKey: .start)
    try container.encodeISO8601InstantIfPresent(end, forKey: .end)
    try container.encode(state, forKey: .state)
    try container.encode(trigger, forKey: .trigger)
    try container.encodeIfPresent(triggerDetail, forKey: .triggerDetail)
    try container.encodeIfPresent(vocab, forKey: .vocab)
  }
}
