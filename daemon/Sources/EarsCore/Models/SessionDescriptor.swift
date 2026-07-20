/// A session's on-disk descriptor, mirroring `session.toml` (see `docs/data-formats.md`).
///
/// A session is metadata over the ring buffer — a named time range across one or
/// more sources — not a separate recording. Mapping to and from TOML belongs to
/// `EarsConfig`. ``end`` is `nil` while the session is open.
public struct SessionDescriptor: Sendable, Hashable, Codable {
  /// Schema version of the `session.toml` format this descriptor was read from.
  public var schema: Int
  /// The session id, e.g. `2026-07-17T10-30-00Z_standup` (start-timestamp + slug).
  public var id: String
  public var slug: String
  public var sources: [SourceID]
  public var start: Instant
  /// End of the session; `nil` while open.
  public var end: Instant?
  public var state: SessionState
  public var trigger: TriggerKind
  /// Trigger provenance, e.g. the bundle id for an app-signal trigger.
  public var triggerDetail: String?
  /// Path to the optional per-session vocabulary file, relative to the data root.
  public var vocab: String?
  /// Seconds of already-buffered ring audio a reader (`transcribe --session`)
  /// should widen this session's effective range backward by, when reading
  /// it -- **not** a shift of ``start`` itself. `start` stays the accurate
  /// historical record of when the session actually opened; pre-roll is a
  /// read-time widening layered on top, since a session is "metadata over
  /// the ring buffer, not a separate recording" (see
  /// `docs/data-formats.md`'s session format, and
  /// `TranscribeRangeResolution`, which applies it). `0` (the
  /// default) means no widening -- every session opened before this field
  /// existed decodes to `0`, matching prior behavior exactly.
  public var preRollSeconds: Int

  public init(
    schema: Int,
    id: String,
    slug: String,
    sources: [SourceID],
    start: Instant,
    end: Instant? = nil,
    state: SessionState,
    trigger: TriggerKind,
    triggerDetail: String? = nil,
    vocab: String? = nil,
    preRollSeconds: Int = 0
  ) {
    self.schema = schema
    self.id = id
    self.slug = slug
    self.sources = sources
    self.start = start
    self.end = end
    self.state = state
    self.trigger = trigger
    self.triggerDetail = triggerDetail
    self.vocab = vocab
    self.preRollSeconds = preRollSeconds
  }

  /// The session's time range once closed, or `nil` while still open.
  public var range: TimeRange? {
    end.map { TimeRange(start: start, end: $0) }
  }
}
