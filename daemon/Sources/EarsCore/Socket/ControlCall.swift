/// One decoded v2 method invocation — a ``ControlMethod`` plus its typed
/// params — everything after the envelope's `id`. `hello` is deliberately
/// absent: the handshake is handled entirely by the transport layer (it needs
/// per-connection state no command handler has), so a `ControlCall` only ever
/// reaches a handler on a connection that already said hello.
public enum ControlCall: Sendable, Hashable {
  case status
  case subscribe(SubscribeParams)

  case sessionStart(SessionStartParams)
  case sessionEnd(session: String)
  case sessionPause(session: String)
  case sessionResume(session: String)
  case sessionRename(SessionRenameParams)
  case sessionAttendee(SessionAttendeeParams)
  case sessionList
  case sessionGet(session: String)
  case sessionRetry(SessionRetryParams)

  case segmentPublish(SegmentPublishParams)
  case jobPublish(JobPublishParams)

  case sourcesList
  case sourcesAdd(SourceSpec)
  case sourcesRemove(source: SourceID)
  case sourcesEnable(source: SourceID)
  case sourcesDisable(source: SourceID)
  case capturePause(source: SourceID?)
  case captureResume(source: SourceID?)
  case flush

  public var method: ControlMethod {
    switch self {
    case .status: .status
    case .subscribe: .subscribe
    case .sessionStart: .sessionStart
    case .sessionEnd: .sessionEnd
    case .sessionPause: .sessionPause
    case .sessionResume: .sessionResume
    case .sessionRename: .sessionRename
    case .sessionAttendee: .sessionAttendee
    case .sessionList: .sessionList
    case .sessionGet: .sessionGet
    case .sessionRetry: .sessionRetry
    case .segmentPublish: .segmentPublish
    case .jobPublish: .jobPublish
    case .sourcesList: .sourcesList
    case .sourcesAdd: .sourcesAdd
    case .sourcesRemove: .sourcesRemove
    case .sourcesEnable: .sourcesEnable
    case .sourcesDisable: .sourcesDisable
    case .capturePause: .capturePause
    case .captureResume: .captureResume
    case .flush: .flush
    }
  }
}

// MARK: - Params types

/// `subscribe` params: which *telemetry* kinds (`vad`, `segment`, `job`) and
/// which sources to receive. State kinds (`session`, `source`) are always
/// delivered — unconditional delivery is what keeps `rev` contiguous — so
/// they are not filterable. Both lists empty/omitted means "everything".
public struct SubscribeParams: Sendable, Hashable, Codable {
  public var events: [EventKind]
  public var sources: [SourceID]

  public init(events: [EventKind] = [], sources: [SourceID] = []) {
    self.events = events
    self.sources = sources
  }

  // Hand-written Codable on both sides suppresses the synthesized
  // CodingKeys, so it is declared explicitly.
  private enum CodingKeys: String, CodingKey {
    case events, sources
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    events = try container.decodeIfPresent([EventKind].self, forKey: .events) ?? []
    sources = try container.decodeIfPresent([SourceID].self, forKey: .sources) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    // Empty lists mean "no filter" and are omitted — the canonical wire form
    // both codecs (Swift and TS) produce, per the golden fixtures.
    var container = encoder.container(keyedBy: CodingKeys.self)
    if !events.isEmpty { try container.encode(events, forKey: .events) }
    if !sources.isEmpty { try container.encode(sources, forKey: .sources) }
  }
}

/// `session.start` params. With `platform`+`externalID` the call is
/// idempotent on that identity; without them it creates a manual session.
/// `sources` seeds the session's source list (`ears session start --source
/// mic`); the roster's `source` links add more later. `trigger` records
/// provenance; defaults to `.manual`.
public struct SessionStartParams: Sendable, Hashable, Codable {
  public var platform: String?
  public var externalID: String?
  public var title: String?
  public var sources: [SourceID]
  public var trigger: TriggerKind?

  public init(
    platform: String? = nil, externalID: String? = nil, title: String? = nil,
    sources: [SourceID] = [], trigger: TriggerKind? = nil
  ) {
    self.platform = platform
    self.externalID = externalID
    self.title = title
    self.sources = sources
    self.trigger = trigger
  }

  private enum CodingKeys: String, CodingKey {
    case platform, title, sources, trigger
    case externalID = "external_id"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
    externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    sources = try container.decodeIfPresent([SourceID].self, forKey: .sources) ?? []
    trigger = try container.decodeIfPresent(TriggerKind.self, forKey: .trigger)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(platform, forKey: .platform)
    try container.encodeIfPresent(externalID, forKey: .externalID)
    try container.encodeIfPresent(title, forKey: .title)
    // Empty means "none named" and is omitted — the canonical wire form.
    if !sources.isEmpty { try container.encode(sources, forKey: .sources) }
    try container.encodeIfPresent(trigger, forKey: .trigger)
  }

  /// The identity to be idempotent on, when both halves were given.
  public var identity: SessionIdentity? {
    guard let platform, let externalID, !platform.isEmpty, !externalID.isEmpty else { return nil }
    return SessionIdentity(platform: platform, externalID: externalID)
  }
}

/// `session.rename` params; `ifRev` makes the rename a compare-and-set
/// (`conflict` on mismatch) instead of silent last-write-wins.
public struct SessionRenameParams: Sendable, Hashable, Codable {
  public var session: String
  public var title: String
  public var ifRev: Int?

  public init(session: String, title: String, ifRev: Int? = nil) {
    self.session = session
    self.title = title
    self.ifRev = ifRev
  }

  private enum CodingKeys: String, CodingKey {
    case session
    case title
    case ifRev = "if_rev"
  }
}

/// `session.retry` params: rerun an ended session's on-end chain from
/// `from` (`transcribe`, `cleanup` or `summarize`). `input` is the artifact
/// the resumed stage reads — the transcript for `cleanup`, the cleaned
/// transcript for `summarize` — and is ignored for `transcribe`.
public struct SessionRetryParams: Sendable, Hashable, Codable {
  public var session: String
  public var from: String
  public var input: String?

  public init(session: String, from: String, input: String? = nil) {
    self.session = session
    self.from = from
    self.input = input
  }
}

/// `session.attendee` params — an upsert keyed by `id` within the session.
/// Omitted fields leave the existing roster entry's values untouched.
public struct SessionAttendeeParams: Sendable, Hashable {
  public var session: String
  public var id: String
  public var displayName: String?
  public var joined: Instant?
  public var left: Instant?
  public var source: SourceID?
  /// Where `id` was minted — see ``AttendeeOrigin``. Omitted means the
  /// client doesn't know (or predates the field) and leaves the stored value
  /// untouched, so an id's provenance survives upserts that don't carry it.
  public var origin: AttendeeOrigin?
  /// `self`: this attendee is the local participant. Omitted leaves the
  /// stored flag alone, so a client that never learns which row is its own
  /// user simply never sets it (and the daemon infers instead) — see
  /// ``SessionAttendee/isLocal``.
  public var isLocal: Bool?

  public init(
    session: String, id: String, displayName: String? = nil,
    joined: Instant? = nil, left: Instant? = nil, source: SourceID? = nil,
    origin: AttendeeOrigin? = nil, isLocal: Bool? = nil
  ) {
    self.session = session
    self.id = id
    self.displayName = displayName
    self.joined = joined
    self.left = left
    self.source = source
    self.origin = origin
    self.isLocal = isLocal
  }
}

extension SessionAttendeeParams: Codable {
  private enum CodingKeys: String, CodingKey {
    case session
    case id, joined, left, source, origin
    case displayName = "display_name"
    case isLocal = "self"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    session = try container.decode(String.self, forKey: .session)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    joined = try container.decodeISO8601InstantIfPresent(forKey: .joined)
    left = try container.decodeISO8601InstantIfPresent(forKey: .left)
    source = try container.decodeIfPresent(SourceID.self, forKey: .source)
    origin = try container.decodeIfPresent(AttendeeOrigin.self, forKey: .origin)
    isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(session, forKey: .session)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeISO8601InstantIfPresent(joined, forKey: .joined)
    try container.encodeISO8601InstantIfPresent(left, forKey: .left)
    try container.encodeIfPresent(source, forKey: .source)
    try container.encodeIfPresent(origin, forKey: .origin)
    try container.encodeIfPresent(isLocal, forKey: .isLocal)
  }
}

/// `segment.publish` params — the notification-only republish a
/// `transcribe --follow` process sends. Keyed by the session whose capture
/// the follow run attached to.
public struct SegmentPublishParams: Sendable, Hashable, Codable {
  public var session: String
  public var speaker: String
  public var start: Double
  public var end: Double
  public var text: String

  public init(session: String, speaker: String, start: Double, end: Double, text: String) {
    self.session = session
    self.speaker = speaker
    self.start = start
    self.end = end
    self.text = text
  }

  private enum CodingKeys: String, CodingKey {
    case session
    case speaker, start, end, text
  }
}

/// A pipeline job's lifecycle state, as reported through `job.publish`.
public enum JobState: String, Sendable, Hashable, Codable, CaseIterable {
  case started
  case running
  case done
  case failed
}

/// `job.publish` params — notification-only, the same pattern as
/// `segment.publish`: pipeline tools report progress, the daemon persists
/// nothing, subscribers get real state instead of guessing.
public struct JobPublishParams: Sendable, Hashable, Codable {
  /// Client-chosen job id, e.g. `transcribe-4fd1a2b0`.
  public var job: String
  /// Today always `transcribe`.
  public var kind: String
  public var session: String?
  public var state: JobState
  public var detail: String?

  public init(
    job: String, kind: String, session: String? = nil,
    state: JobState, detail: String? = nil
  ) {
    self.job = job
    self.kind = kind
    self.session = session
    self.state = state
    self.detail = detail
  }

  private enum CodingKeys: String, CodingKey {
    case session
    case job, kind, state, detail
  }
}
