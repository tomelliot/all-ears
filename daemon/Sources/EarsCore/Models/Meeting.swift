/// The daemon-owned meeting lifecycle entity of control protocol v2
/// (`docs/product/specs/control-protocol.md`'s "Meeting"): layered *above*
/// sessions, owning transcription marks (``intervals``), the attendee roster,
/// and the title. Persisted as `meetings/<uuid>/meeting.toml` (schema 2, see
/// `EarsConfig.MeetingDescriptorTOML`) plus an append-only `events.jsonl`
/// timeline; its `Codable` conformance is the v2 *wire* shape (snake_case,
/// ISO-8601 instants) carried in `meeting.*` results and `meeting` events.
///
/// Intervals are marks over the ring buffer, never capture control: pausing a
/// meeting closes the open interval, resuming opens a new one, and the
/// capture engines/ingest streams are untouched throughout.
public struct Meeting: Sendable, Hashable {
  /// The daemon-assigned meeting UUID — the one internal id used everywhere
  /// (materialized session slugs, filenames, CLI output).
  public var id: String
  /// The platform-specific external identity `meeting.start` is idempotent
  /// on; `nil` for manual meetings.
  public var identity: MeetingIdentity?
  /// Renameable display title; defaults from ``identity`` (or the id) when
  /// the client never named one.
  public var title: String
  public var state: MeetingState
  public var started: Instant
  /// Set once on `meeting.end`; `nil` while active/paused.
  public var ended: Instant?
  /// Transcription marks over the ring buffer. A `nil` interval end means
  /// "currently marked" (the meeting is active).
  public var intervals: [MeetingInterval]
  /// The roster, upserted by whoever knows it (the extension's DOM layer
  /// today).
  public var attendees: [MeetingAttendee]
  /// Every source involved in this meeting — what materialized sessions
  /// record, and (for `browser:*` entries) what the orphan grace timer
  /// watches.
  public var sources: [SourceID]
  /// Provenance, preserved onto every materialized session.
  public var trigger: TriggerKind
  /// The last state revision that touched this meeting. Boot-scoped (see
  /// `hello`'s `boot_id`), so never persisted to `meeting.toml`.
  public var rev: Int

  public init(
    id: String,
    identity: MeetingIdentity? = nil,
    title: String,
    state: MeetingState,
    started: Instant,
    ended: Instant? = nil,
    intervals: [MeetingInterval] = [],
    attendees: [MeetingAttendee] = [],
    sources: [SourceID] = [],
    trigger: TriggerKind = .manual,
    rev: Int = 0
  ) {
    self.id = id
    self.identity = identity
    self.title = title
    self.state = state
    self.started = started
    self.ended = ended
    self.intervals = intervals
    self.attendees = attendees
    self.sources = sources
    self.trigger = trigger
    self.rev = rev
  }

  /// Whether any of this meeting's sources is a `browser:*` source — the
  /// discriminator for the orphaned-meeting policy (browser meetings
  /// auto-end after the ingest-close grace; manual meetings never do).
  public var isBrowserMeeting: Bool {
    sources.contains { $0.sourceClass == .browser }
  }
}

/// A meeting's lifecycle state.
public enum MeetingState: String, Sendable, Hashable, Codable, CaseIterable {
  case active
  case paused
  case ended
}

/// The platform-specific external identity `meeting.start` is idempotent on.
public struct MeetingIdentity: Sendable, Hashable, Codable {
  /// e.g. `meet`.
  public var platform: String
  /// The platform's own meeting identifier, e.g. Meet's `<space>` segment.
  public var externalID: String

  public init(platform: String, externalID: String) {
    self.platform = platform
    self.externalID = externalID
  }

  private enum CodingKeys: String, CodingKey {
    case platform
    case externalID = "external_id"
  }
}

/// One transcription mark over the ring buffer; `end == nil` means the span
/// is currently marked.
public struct MeetingInterval: Sendable, Hashable {
  public var start: Instant
  public var end: Instant?

  public init(start: Instant, end: Instant? = nil) {
    self.start = start
    self.end = end
  }
}

/// One roster entry, with join/leave times and an optional mapping to the
/// attendee's per-participant audio source (which downstream feeds the
/// transcript's speaker-name map).
public struct MeetingAttendee: Sendable, Hashable {
  /// The platform's participant id, e.g. `spaces/x/devices/y`.
  public var id: String
  public var displayName: String?
  public var joined: Instant?
  public var left: Instant?
  /// The attendee's per-participant audio source, when known.
  public var source: SourceID?

  public init(
    id: String,
    displayName: String? = nil,
    joined: Instant? = nil,
    left: Instant? = nil,
    source: SourceID? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.joined = joined
    self.left = left
    self.source = source
  }
}

// MARK: - Wire coding (v2 JSON: snake_case keys, ISO-8601 instants)

extension Meeting: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, identity, title, state, started, ended, intervals, attendees, sources, trigger, rev
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    identity = try container.decodeIfPresent(MeetingIdentity.self, forKey: .identity)
    title = try container.decode(String.self, forKey: .title)
    state = try container.decode(MeetingState.self, forKey: .state)
    started = try container.decodeISO8601Instant(forKey: .started)
    ended = try container.decodeISO8601InstantIfPresent(forKey: .ended)
    intervals = try container.decodeIfPresent([MeetingInterval].self, forKey: .intervals) ?? []
    attendees = try container.decodeIfPresent([MeetingAttendee].self, forKey: .attendees) ?? []
    sources = try container.decodeIfPresent([SourceID].self, forKey: .sources) ?? []
    trigger = try container.decode(TriggerKind.self, forKey: .trigger)
    rev = try container.decodeIfPresent(Int.self, forKey: .rev) ?? 0
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(identity, forKey: .identity)
    try container.encode(title, forKey: .title)
    try container.encode(state, forKey: .state)
    try container.encodeISO8601Instant(started, forKey: .started)
    try container.encodeISO8601InstantIfPresent(ended, forKey: .ended)
    try container.encode(intervals, forKey: .intervals)
    try container.encode(attendees, forKey: .attendees)
    try container.encode(sources, forKey: .sources)
    try container.encode(trigger, forKey: .trigger)
    try container.encode(rev, forKey: .rev)
  }
}

extension MeetingInterval: Codable {
  private enum CodingKeys: String, CodingKey {
    case start, end
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    start = try container.decodeISO8601Instant(forKey: .start)
    end = try container.decodeISO8601InstantIfPresent(forKey: .end)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeISO8601Instant(start, forKey: .start)
    // Always written (as `null` while open) so "currently marked" is
    // explicit in the spec's literal example shape.
    switch end {
    case .some(let end): try container.encodeISO8601Instant(end, forKey: .end)
    case .none: try container.encodeNil(forKey: .end)
    }
  }
}

extension MeetingAttendee: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, joined, left, source
    case displayName = "display_name"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    joined = try container.decodeISO8601InstantIfPresent(forKey: .joined)
    left = try container.decodeISO8601InstantIfPresent(forKey: .left)
    source = try container.decodeIfPresent(SourceID.self, forKey: .source)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeISO8601InstantIfPresent(joined, forKey: .joined)
    try container.encodeISO8601InstantIfPresent(left, forKey: .left)
    try container.encodeIfPresent(source, forKey: .source)
  }
}
