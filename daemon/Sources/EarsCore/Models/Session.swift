/// The daemon-owned session lifecycle entity of control protocol v2
/// (`docs/specs/control-protocol.md`): owns the
/// transcription marks (``intervals``), the attendee roster, and the title.
/// Persisted as `sessions/<uuid>/session.toml` (schema 3, see
/// `EarsConfig.SessionDescriptorTOML`) plus an append-only `events.jsonl`
/// timeline; its `Codable` conformance is the v2 *wire* shape (snake_case,
/// ISO-8601 instants) carried in `session.*` results and `session` events.
///
/// Intervals are marks over the recording, never capture control: pausing a
/// session closes the open interval, resuming opens a new one, and the
/// capture engines/ingest streams are untouched throughout.
public struct Session: Sendable, Hashable {
  /// The daemon-assigned session UUID — the one internal id used everywhere
  /// (filenames, CLI output).
  public var id: String
  /// The platform-specific external identity `session.start` is idempotent
  /// on; `nil` for manual sessions.
  public var identity: SessionIdentity?
  /// Renameable display title; defaults from ``identity`` (or the id) when
  /// the client never named one.
  public var title: String
  public var state: SessionState
  public var started: Instant
  /// Set once on `session.end`; `nil` while active/paused.
  public var ended: Instant?
  /// Transcription marks over the recording. A `nil` interval end means
  /// "currently marked" (the session is active).
  public var intervals: [SessionInterval]
  /// The roster, upserted by whoever knows it (the extension's DOM layer
  /// today). *Observed* fact — see ``speakers`` for what is derived from it.
  public var attendees: [SessionAttendee]
  /// The reconciled source → speaker-name map, derived from ``attendees`` at
  /// `session.end` by ``RosterReconciler`` and persisted so the derivation is
  /// inspectable and re-runnable rather than implicit in whichever live
  /// correlation happened to win.
  ///
  /// Empty until the session ends. Transcription labels turns from this, not
  /// from the roster's raw `source` bindings.
  public var speakers: [SessionSpeaker]
  /// What reconciliation could not resolve, or resolved by inference —
  /// carried into the transcript's frontmatter and the note itself, so a
  /// degraded run is visible where the user reads rather than only in a log.
  public var warnings: [String]
  /// Which ``RosterReconciler`` version derived ``speakers`` — see
  /// `RosterReconciler.version`. 0 until the session is reconciled, and for
  /// any `session.toml` written before the field existed; `transcribe`
  /// re-derives a map whose version is older than the current reconciler's,
  /// which is what makes a reconciler fix repair past sessions. Persisted in
  /// `session.toml` only, never on the wire: clients consume the map, not
  /// the provenance of its derivation.
  public var reconcilerVersion: Int
  /// Every source involved in this session — what transcription reads, and
  /// (for `browser:*` entries) what the orphan grace timer watches.
  public var sources: [SourceID]
  /// Provenance: what started this session.
  public var trigger: TriggerKind
  /// When this session's transcript last completed **successfully** — the
  /// durable marker retention keys off (`docs/specs/capture-daemon.md`'s
  /// "Retention"). `nil` until a transcript run succeeds; once set, the
  /// session's audio is evicted `evict_after_transcript_seconds` later. A
  /// session whose transcript never succeeds keeps this `nil` and its audio is
  /// instead retained until `max_audio_age_seconds` after it ended.
  public var transcriptCompleted: Instant?
  /// What the last on-end stage chain reported: a stage that failed, or one
  /// that succeeded with a `warning:`. Replaced wholesale by each chain run.
  /// Kept apart from ``warnings``, which feed the transcript's frontmatter.
  public var pipelineIssues: [PipelineIssue]
  /// Absolute paths of the notes the last on-end chain's `summarize` wrote.
  /// Replaced wholesale by each chain run. `summarize` reads every other
  /// session's list so it never takes a note another call already produced
  /// as this call's jotted notes. Persisted in `session.toml` only, never on
  /// the wire, like ``reconcilerVersion``.
  public var publishedNotes: [String]
  /// The last state revision that touched this session. Boot-scoped (see
  /// `hello`'s `boot_id`), so never persisted to `session.toml`.
  public var rev: Int

  public init(
    id: String,
    identity: SessionIdentity? = nil,
    title: String,
    state: SessionState,
    started: Instant,
    ended: Instant? = nil,
    intervals: [SessionInterval] = [],
    attendees: [SessionAttendee] = [],
    speakers: [SessionSpeaker] = [],
    warnings: [String] = [],
    sources: [SourceID] = [],
    trigger: TriggerKind = .manual,
    transcriptCompleted: Instant? = nil,
    pipelineIssues: [PipelineIssue] = [],
    publishedNotes: [String] = [],
    reconcilerVersion: Int = 0,
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
    self.speakers = speakers
    self.warnings = warnings
    self.sources = sources
    self.trigger = trigger
    self.transcriptCompleted = transcriptCompleted
    self.pipelineIssues = pipelineIssues
    self.publishedNotes = publishedNotes
    self.reconcilerVersion = reconcilerVersion
    self.rev = rev
  }

  /// The title a session gets when no client ever names one: the platform
  /// and its own meeting identifier, e.g. `meet wUE9lE2sg5YB` — or, for a
  /// manual session, `session` and its UTC start to the minute, e.g.
  /// `session 2026-07-17 10:30`.
  ///
  /// Unreadable in a file listing and unsearchable, so it is a last resort
  /// rather than a default anyone should end up with — see
  /// ``RosterReconciler/derivedTitle(attendees:localAttendeeID:)``. The
  /// manual default carries `started` because the recompute-and-compare
  /// detection below forces the default to be a pure function of the
  /// session's own fields: with a shared constant (`"session"`, the old
  /// shape) every unnamed manual session was titled identically, so their
  /// listings and derived notes were indistinguishable and collided.
  public static func defaultTitle(identity: SessionIdentity?, started: Instant) -> String {
    guard let identity else {
      let time = String(UTCCalendar.timeOfDay(started).prefix(5))  // HH:MM
      return "session \(UTCCalendar.isoDate(started)) \(time)"
    }
    return "\(identity.platform) \(identity.externalID)"
  }

  /// Whether this session is still carrying ``defaultTitle(identity:started:)``
  /// — i.e. nothing has named it.
  ///
  /// Recomputed and compared rather than tracked with a flag, which is what
  /// makes title precedence need no extra state: a meeting name scraped from
  /// the window title, and a rename typed by hand, both take precedence
  /// simply by having changed the title away from this.
  public var hasDefaultTitle: Bool {
    title == Self.defaultTitle(identity: identity, started: started)
  }

  /// Whether any of this session's sources is a `browser:*` source — the
  /// discriminator for the orphaned-session policy (browser sessions
  /// auto-end after the ingest-close grace; manual sessions never do).
  public var isBrowserSession: Bool {
    sources.contains { $0.sourceClass == .browser }
  }
}

/// A session's lifecycle state.
public enum SessionState: String, Sendable, Hashable, Codable, CaseIterable {
  case active
  case paused
  case ended
}

/// The platform-specific external identity `session.start` is idempotent on.
public struct SessionIdentity: Sendable, Hashable, Codable {
  /// e.g. `meet`.
  public var platform: String
  /// The platform's own meeting identifier (the platform concept keeps the
  /// name "meeting"), e.g. Meet's `<space>` segment.
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

/// One thing an on-end pipeline stage reported about its run.
public struct PipelineIssue: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Hashable, Codable {
    /// The stage exited non-zero or broke its result contract.
    case failed
    /// The stage succeeded but wrote a `warning:` line.
    case warning
  }

  /// `transcribe`, `cleanup` or `summarize`.
  public var stage: String
  public var kind: Kind
  /// The stage's own error or warning text, without its `error:`/`warning:`
  /// prefix.
  public var message: String
  /// The exit-code class label (`retryable-upstream`) of a failure; `nil` for
  /// a warning.
  public var exitClass: String?

  public init(stage: String, kind: Kind, message: String, exitClass: String? = nil) {
    self.stage = stage
    self.kind = kind
    self.message = message
    self.exitClass = exitClass
  }

  private enum CodingKeys: String, CodingKey {
    case stage, kind, message
    case exitClass = "exit_class"
  }
}

/// One transcription mark over the recording; `end == nil` means the span
/// is currently marked.
public struct SessionInterval: Sendable, Hashable {
  public var start: Instant
  public var end: Instant?

  public init(start: Instant, end: Instant? = nil) {
    self.start = start
    self.end = end
  }
}

/// Where a roster entry's ``SessionAttendee/id`` was minted.
///
/// The capture client reports it on `session.attendee` (`origin`), flattened
/// from its typed participant reference. The distinction is load-bearing for
/// reconciliation: a synthetic row names a captured track, not a person, so
/// ``RosterReconciler`` never counts it as a named remote participant —
/// see ``RosterReconciler/namedRemoteAttendees(_:localID:)``.
public enum AttendeeOrigin: String, Sendable, Hashable, Codable, CaseIterable {
  /// The platform's own stable id (a Meet device path, a Zoom node id),
  /// joinable against the platform's roster.
  case platform
  /// A capture-client stand-in minted when no platform id was available
  /// (`speaker-<n>`, `webaudio-track-<n>`, `graphtap-<n>`).
  case synthetic
}

/// One roster entry, with join/leave times and an optional mapping to the
/// attendee's per-participant audio source (which downstream feeds the
/// transcript's speaker-name map).
public struct SessionAttendee: Sendable, Hashable {
  /// The participant id the capture client upserted under — usually the
  /// platform's own (e.g. `spaces/x/devices/y`), sometimes a synthetic
  /// stand-in; ``origin`` says which.
  public var id: String
  public var displayName: String?
  public var joined: Instant?
  public var left: Instant?
  /// The attendee's per-participant audio source, when known.
  ///
  /// A *guess*, unlike the rest of this struct: the capture client pairs an
  /// audio track to a participant id by temporal coincidence, and coincidences
  /// are occasionally wrong. ``RosterReconciler`` is what turns these into the
  /// speaker map, applying the invariants a binding has to satisfy first.
  public var source: SourceID?
  /// Where ``id`` was minted — see ``AttendeeOrigin``. `nil` means unknown:
  /// the roster row predates provenance (old `session.toml` files, old
  /// clients), and every consumer treats an unknown row exactly as it did
  /// before origins existed.
  public var origin: AttendeeOrigin?
  /// Whether this attendee is the local participant — you.
  ///
  /// Reported by the capture client, which can see the platform's own "(You)"
  /// marker. Load-bearing rather than cosmetic: the local participant is
  /// captured on `mic`, so a `browser:*` track bound to them is an impossible
  /// state, and it is the one that produced a whole call transcribed under the
  /// wrong person's name (journal #158/#172). ``RosterReconciler`` falls back
  /// to inferring it from join order when the client never says.
  public var isLocal: Bool

  public init(
    id: String,
    displayName: String? = nil,
    joined: Instant? = nil,
    left: Instant? = nil,
    source: SourceID? = nil,
    origin: AttendeeOrigin? = nil,
    isLocal: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.joined = joined
    self.left = left
    self.source = source
    self.origin = origin
    self.isLocal = isLocal
  }
}

// MARK: - Wire coding (v2 JSON: snake_case keys, ISO-8601 instants)

extension Session: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, identity, title, state, started, ended, intervals, attendees, speakers, warnings
    case sources, trigger, rev
    case transcriptCompleted = "transcript_completed"
    case pipelineIssues = "pipeline_issues"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    identity = try container.decodeIfPresent(SessionIdentity.self, forKey: .identity)
    title = try container.decode(String.self, forKey: .title)
    state = try container.decode(SessionState.self, forKey: .state)
    started = try container.decodeISO8601Instant(forKey: .started)
    ended = try container.decodeISO8601InstantIfPresent(forKey: .ended)
    intervals = try container.decodeIfPresent([SessionInterval].self, forKey: .intervals) ?? []
    attendees = try container.decodeIfPresent([SessionAttendee].self, forKey: .attendees) ?? []
    speakers = try container.decodeIfPresent([SessionSpeaker].self, forKey: .speakers) ?? []
    warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    sources = try container.decodeIfPresent([SourceID].self, forKey: .sources) ?? []
    trigger = try container.decode(TriggerKind.self, forKey: .trigger)
    transcriptCompleted = try container.decodeISO8601InstantIfPresent(forKey: .transcriptCompleted)
    pipelineIssues =
      try container.decodeIfPresent([PipelineIssue].self, forKey: .pipelineIssues) ?? []
    // TOML-only (see the properties' doc comments): the wire shape neither
    // carries nor needs them, so decoding always starts them empty.
    publishedNotes = []
    reconcilerVersion = 0
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
    try container.encode(speakers, forKey: .speakers)
    try container.encode(warnings, forKey: .warnings)
    try container.encode(sources, forKey: .sources)
    try container.encode(trigger, forKey: .trigger)
    try container.encodeISO8601InstantIfPresent(transcriptCompleted, forKey: .transcriptCompleted)
    // Omitted when empty, so every frame without issues stays byte-identical
    // to the shared golden fixtures.
    if !pipelineIssues.isEmpty {
      try container.encode(pipelineIssues, forKey: .pipelineIssues)
    }
    try container.encode(rev, forKey: .rev)
  }
}

extension SessionInterval: Codable {
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

extension SessionAttendee: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, joined, left, source, origin
    case displayName = "display_name"
    // `self` on the wire: it reads as the platform's own "(You)" marker,
    // which is what the capture client is relaying.
    case isLocal = "self"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    joined = try container.decodeISO8601InstantIfPresent(forKey: .joined)
    left = try container.decodeISO8601InstantIfPresent(forKey: .left)
    source = try container.decodeIfPresent(SourceID.self, forKey: .source)
    origin = try container.decodeIfPresent(AttendeeOrigin.self, forKey: .origin)
    isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeISO8601InstantIfPresent(joined, forKey: .joined)
    try container.encodeISO8601InstantIfPresent(left, forKey: .left)
    try container.encodeIfPresent(source, forKey: .source)
    // Absent = unknown, so an unknown origin is omitted, never invented.
    try container.encodeIfPresent(origin, forKey: .origin)
    // Written only when true: an absent `self` and `self: false` mean the
    // same thing, and every roster is mostly the latter.
    if isLocal { try container.encode(true, forKey: .isLocal) }
  }
}
