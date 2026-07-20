/// One decoded v2 method invocation — a ``ControlMethod`` plus its typed
/// params — everything after the envelope's `id`. `hello` is deliberately
/// absent: the handshake is handled entirely by the transport layer (it needs
/// per-connection state no command handler has), so a `ControlCall` only ever
/// reaches a handler on a connection that already said hello.
public enum ControlCall: Sendable, Hashable {
  case status
  case subscribe(SubscribeParams)

  case meetingStart(MeetingStartParams)
  case meetingEnd(meeting: String)
  case meetingPause(meeting: String)
  case meetingResume(meeting: String)
  case meetingRename(MeetingRenameParams)
  case meetingAttendee(MeetingAttendeeParams)
  case meetingList
  case meetingGet(meeting: String)

  case sessionOpen(SessionOpenParams)
  case sessionClose(id: String)
  case sessionList
  case sessionAddSource(id: String, source: SourceID)
  case mark(sources: [SourceID], slug: String, range: MarkRange)
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
    case .meetingStart: .meetingStart
    case .meetingEnd: .meetingEnd
    case .meetingPause: .meetingPause
    case .meetingResume: .meetingResume
    case .meetingRename: .meetingRename
    case .meetingAttendee: .meetingAttendee
    case .meetingList: .meetingList
    case .meetingGet: .meetingGet
    case .sessionOpen: .sessionOpen
    case .sessionClose: .sessionClose
    case .sessionList: .sessionList
    case .sessionAddSource: .sessionAddSource
    case .mark: .mark
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
/// which sources to receive. State kinds (`meeting`, `session`, `source`) are
/// always delivered — unconditional delivery is what keeps `rev` contiguous —
/// so they are not filterable. Both lists empty/omitted means "everything".
public struct SubscribeParams: Sendable, Hashable, Codable {
  public var events: [EventKind]
  public var sources: [SourceID]

  public init(events: [EventKind] = [], sources: [SourceID] = []) {
    self.events = events
    self.sources = sources
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

/// `meeting.start` params. With `platform`+`externalID` the call is
/// idempotent on that identity; without them it creates a manual meeting.
/// `sources` seeds the meeting's source list (`ears meeting start --source
/// mic`); the roster's `source` links add more later. `trigger` records
/// provenance (preserved onto materialized sessions); defaults to `.manual`.
public struct MeetingStartParams: Sendable, Hashable, Codable {
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
  public var identity: MeetingIdentity? {
    guard let platform, let externalID, !platform.isEmpty, !externalID.isEmpty else { return nil }
    return MeetingIdentity(platform: platform, externalID: externalID)
  }
}

/// `meeting.rename` params; `ifRev` makes the rename a compare-and-set
/// (`conflict` on mismatch) instead of silent last-write-wins.
public struct MeetingRenameParams: Sendable, Hashable, Codable {
  public var meeting: String
  public var title: String
  public var ifRev: Int?

  public init(meeting: String, title: String, ifRev: Int? = nil) {
    self.meeting = meeting
    self.title = title
    self.ifRev = ifRev
  }

  private enum CodingKeys: String, CodingKey {
    case meeting, title
    case ifRev = "if_rev"
  }
}

/// `meeting.attendee` params — an upsert keyed by `id` within the meeting.
/// Omitted fields leave the existing roster entry's values untouched.
public struct MeetingAttendeeParams: Sendable, Hashable {
  public var meeting: String
  public var id: String
  public var displayName: String?
  public var joined: Instant?
  public var left: Instant?
  public var source: SourceID?

  public init(
    meeting: String, id: String, displayName: String? = nil,
    joined: Instant? = nil, left: Instant? = nil, source: SourceID? = nil
  ) {
    self.meeting = meeting
    self.id = id
    self.displayName = displayName
    self.joined = joined
    self.left = left
    self.source = source
  }
}

extension MeetingAttendeeParams: Codable {
  private enum CodingKeys: String, CodingKey {
    case meeting, id, joined, left, source
    case displayName = "display_name"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    meeting = try container.decode(String.self, forKey: .meeting)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    joined = try container.decodeISO8601InstantIfPresent(forKey: .joined)
    left = try container.decodeISO8601InstantIfPresent(forKey: .left)
    source = try container.decodeIfPresent(SourceID.self, forKey: .source)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(meeting, forKey: .meeting)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeISO8601InstantIfPresent(joined, forKey: .joined)
    try container.encodeISO8601InstantIfPresent(left, forKey: .left)
    try container.encodeIfPresent(source, forKey: .source)
  }
}

/// `session.open` params — same fields as v1's flat command.
public struct SessionOpenParams: Sendable, Hashable {
  public var sources: [SourceID]
  public var slug: String
  public var start: Instant?
  public var vocab: String?
  public var trigger: TriggerKind?

  public init(
    sources: [SourceID], slug: String, start: Instant? = nil, vocab: String? = nil,
    trigger: TriggerKind? = nil
  ) {
    self.sources = sources
    self.slug = slug
    self.start = start
    self.vocab = vocab
    self.trigger = trigger
  }
}

extension SessionOpenParams: Codable {
  private enum CodingKeys: String, CodingKey {
    case sources, slug, start, vocab, trigger
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sources = try container.decode([SourceID].self, forKey: .sources)
    slug = try container.decode(String.self, forKey: .slug)
    start = try container.decodeISO8601InstantIfPresent(forKey: .start)
    vocab = try container.decodeIfPresent(String.self, forKey: .vocab)
    trigger = try container.decodeIfPresent(TriggerKind.self, forKey: .trigger)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sources, forKey: .sources)
    try container.encode(slug, forKey: .slug)
    try container.encodeISO8601InstantIfPresent(start, forKey: .start)
    try container.encodeIfPresent(vocab, forKey: .vocab)
    try container.encodeIfPresent(trigger, forKey: .trigger)
  }
}

/// `segment.publish` params — the notification-only republish a
/// `transcribe --follow` process sends, unchanged from v1 in all but envelope.
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
  public var meeting: String?
  public var session: String?
  public var state: JobState
  public var detail: String?

  public init(
    job: String, kind: String, meeting: String? = nil, session: String? = nil,
    state: JobState, detail: String? = nil
  ) {
    self.job = job
    self.kind = kind
    self.meeting = meeting
    self.session = session
    self.state = state
    self.detail = detail
  }
}
