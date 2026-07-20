import EarsCore
import EarsDataStore
import Foundation

/// Errors surfaced by ``MeetingRegistry``, mapped 1:1 onto the v2 wire's
/// stable error codes by `ControlServer`.
public enum MeetingRegistryError: Error, Sendable, Hashable {
  /// No meeting (live or on disk) has this id → `meeting_not_found`.
  case notFound(String)
  /// A lifecycle verb targeted a meeting that has already ended →
  /// `meeting_ended`.
  case ended(String)
  /// `meeting.rename`'s `if_rev` didn't match the meeting's current
  /// revision → `conflict`.
  case conflict(String)
}

/// Owns the v2 **Meeting** lifecycle (`docs/product/specs/control-protocol.md`):
/// start (idempotent on identity), pause/resume as interval marks, the
/// attendee roster, rename, end-with-materialization, and the orphaned-
/// meeting grace policy. This is what v1's client-side meeting tracker
/// becomes — the daemon, not any frontend, owns the state machine.
///
/// ## Persistence
///
/// Every mutation writes `meetings/<uuid>/meeting.toml` (schema 2) atomically
/// via ``MeetingStore`` and appends the domain event to the meeting's
/// `events.jsonl` (best-effort — the timeline is for disk consumers, never
/// load-bearing for protocol sync). Active/paused meetings reload at daemon
/// start via ``loadFromDisk()``, which is what lets a meeting survive a
/// daemon restart.
///
/// ## Intervals are marks, never capture control
///
/// Pausing closes the open interval; resuming opens a new one. Nothing here
/// references a `CaptureActor` — the ring buffer and ingest streams are
/// untouched by design.
///
/// ## Orphaned meetings
///
/// Browser meetings (any `browser:*` source) auto-end with
/// `reason = "ingest-idle"` once their last live ingest stream has been
/// closed for `graceSeconds` with no re-open — `EarsDaemon` feeds
/// ``ingestStreamOpened(source:)``/``ingestStreamClosed(source:)`` from the
/// ingest WebSocket. Manual meetings are never auto-ended: the daemon
/// records, it doesn't decide.
public actor MeetingRegistry {
  /// Why a meeting ended, recorded in `events.jsonl`'s `ended` line.
  public enum EndReason: String, Sendable {
    /// An explicit `meeting.end`.
    case client
    /// The orphan grace timer fired.
    case ingestIdle = "ingest-idle"
  }

  /// Called after every meeting end with the final meeting and the sessions
  /// materialized from its intervals — the seam ``EarsDaemon`` hangs
  /// auto-transcription off.
  public typealias EndedHook = @Sendable (Meeting, [SessionDescriptor]) async -> Void

  private let dataRoot: URL
  private let clock: any NowProviding
  /// Mints a new meeting id — injected so tests get deterministic ids.
  private let makeID: @Sendable () -> String
  /// The live-feed publisher (revision assignment included); `nil` publishes
  /// nothing.
  private let bus: EventBus?
  private let log: @Sendable (String) -> Void
  /// `[earsd.meetings].ingest_close_grace_s`.
  private let graceSeconds: Double
  /// Injectable wait, so orphan-grace tests never sleep real time.
  private let sleep: @Sendable (Double) async -> Void
  private let sessionSchema: Int
  private let onEnded: EndedHook?

  /// Live (active/paused) and recently-ended meetings, keyed by id. Ended
  /// meetings from *before* this boot stay on disk only.
  private var meetings: [String: Meeting] = [:]
  /// `(platform, externalID)` → live meeting id, for `meeting.start`'s
  /// idempotency. Ended meetings drop out — rejoining an ended meeting's
  /// identity starts a fresh one.
  private var byIdentity: [MeetingIdentity: String] = [:]
  /// Live ingest streams per source, fed by `EarsDaemon`.
  private var liveIngest: [SourceID: Int] = [:]
  /// Grace-timer invalidation: a scheduled expiry only fires if the
  /// meeting's generation still matches (a re-opened stream bumps it).
  private var graceGeneration: [String: Int] = [:]

  public init(
    dataRoot: URL,
    clock: any NowProviding = SystemClock(),
    makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
    bus: EventBus? = nil,
    graceSeconds: Double = 120,
    sleep: @escaping @Sendable (Double) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    sessionSchema: Int = ActorContracts.sessionSchemaVersion,
    onEnded: EndedHook? = nil,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.makeID = makeID
    self.bus = bus
    self.graceSeconds = graceSeconds
    self.sleep = sleep
    self.sessionSchema = sessionSchema
    self.onEnded = onEnded
    self.log = log
  }

  // MARK: - Startup

  /// Reloads every non-ended meeting from disk — called once at daemon
  /// start. An `active` meeting with an open interval survives a restart
  /// as-is; a reloaded *browser* meeting whose streams don't return starts
  /// its orphan grace clock from daemon boot.
  public func loadFromDisk() {
    for meeting in MeetingStore.readAll(
      dataRoot: dataRoot,
      onSkip: { [log] id, error in log("meeting registry: skipping meetings/\(id): \(error)") })
    where meeting.state != .ended {
      meetings[meeting.id] = meeting
      if let identity = meeting.identity {
        byIdentity[identity] = meeting.id
      }
      if meeting.isBrowserMeeting {
        scheduleGraceExpiry(meetingID: meeting.id)
      }
    }
  }

  // MARK: - Lifecycle verbs

  /// `meeting.start`. Idempotent on `identity`: re-declaring a live meeting
  /// returns its current state (merging any newly-named sources) — the
  /// recovery path for service-worker eviction and daemon restart alike.
  /// Without an identity this creates a manual meeting.
  public func start(_ params: MeetingStartParams) async throws -> Meeting {
    if let identity = params.identity,
      let existingID = byIdentity[identity],
      var existing = meetings[existingID],
      existing.state != .ended
    {
      let merged = mergeSources(params.sources, into: &existing)
      if merged {
        try persist(existing)
        await publish(&existing)
      }
      meetings[existing.id] = existing
      return existing
    }

    let now = clock.now()
    let identity = params.identity
    var meeting = Meeting(
      id: makeID(),
      identity: identity,
      title: params.title ?? Self.defaultTitle(identity: identity),
      state: .active,
      started: now,
      intervals: [MeetingInterval(start: now)],
      sources: params.sources,
      trigger: params.trigger ?? .manual)
    try persist(meeting)
    appendEvent(meeting.id, event: "started", at: now)
    appendEvent(meeting.id, event: "interval_opened", at: now)
    await publish(&meeting)
    meetings[meeting.id] = meeting
    if let identity {
      byIdentity[identity] = meeting.id
    }
    return meeting
  }

  /// `meeting.end`: closes the open interval, materializes one closed
  /// session per interval (slug = meeting UUID, trigger preserved, roster
  /// written into each session's `[speakers]` map), and fires the ended
  /// hook. Idempotent: ending an already-ended (still-known) meeting
  /// returns its final state.
  @discardableResult
  public func end(id: String, reason: EndReason = .client) async throws -> Meeting {
    guard var meeting = knownMeeting(id) else {
      throw MeetingRegistryError.notFound(id)
    }
    if meeting.state == .ended {
      return meeting
    }
    let now = clock.now()
    if closeOpenInterval(of: &meeting, at: now) {
      appendEvent(meeting.id, event: "interval_closed", at: now)
    }
    meeting.state = .ended
    meeting.ended = now

    let sessions = materializeSessions(for: meeting)
    try persist(meeting)
    appendEvent(meeting.id, event: "ended", at: now, reason: reason.rawValue)
    await publish(&meeting)
    for session in sessions {
      await bus?.publish(.session(SessionSummary(session)))
    }
    meetings[meeting.id] = meeting
    if let identity = meeting.identity, byIdentity[identity] == meeting.id {
      byIdentity[identity] = nil
    }
    graceGeneration[meeting.id] = nil

    if let onEnded {
      await onEnded(meeting, sessions)
    }
    return meeting
  }

  /// `meeting.pause`: closes the open interval. No-op success if already
  /// paused; `meeting_ended` if the meeting is over.
  public func pause(id: String) async throws -> Meeting {
    var meeting = try liveMeeting(id)
    guard meeting.state == .active else {
      return meeting  // already paused — converge, don't error
    }
    let now = clock.now()
    if closeOpenInterval(of: &meeting, at: now) {
      appendEvent(meeting.id, event: "interval_closed", at: now)
    }
    meeting.state = .paused
    try persist(meeting)
    await publish(&meeting)
    meetings[meeting.id] = meeting
    return meeting
  }

  /// `meeting.resume`: opens a new interval. No-op success if already
  /// active; `meeting_ended` if the meeting is over.
  public func resume(id: String) async throws -> Meeting {
    var meeting = try liveMeeting(id)
    guard meeting.state == .paused else {
      return meeting  // already active — converge, don't error
    }
    let now = clock.now()
    meeting.intervals.append(MeetingInterval(start: now))
    meeting.state = .active
    appendEvent(meeting.id, event: "interval_opened", at: now)
    try persist(meeting)
    await publish(&meeting)
    meetings[meeting.id] = meeting
    return meeting
  }

  /// `meeting.rename`. `ifRev` makes it a compare-and-set: a mismatch
  /// throws `conflict` instead of silently last-write-winning.
  public func rename(id: String, title: String, ifRev: Int?) async throws -> Meeting {
    guard var meeting = knownMeeting(id) else {
      throw MeetingRegistryError.notFound(id)
    }
    if let ifRev, ifRev != meeting.rev {
      throw MeetingRegistryError.conflict(
        "meeting '\(id)' is at rev \(meeting.rev), not \(ifRev)")
    }
    meeting.title = title
    try persist(meeting)
    appendEvent(meeting.id, event: "renamed", at: clock.now(), title: title)
    await publish(&meeting)
    meetings[meeting.id] = meeting
    return meeting
  }

  /// `meeting.attendee`: upsert by attendee `id`. Omitted fields keep the
  /// existing entry's values; a `source` link also joins the meeting's
  /// source list.
  public func upsertAttendee(_ params: MeetingAttendeeParams) async throws -> Meeting {
    var meeting = try liveMeeting(params.meeting)
    let now = clock.now()

    var attendee =
      meeting.attendees.first(where: { $0.id == params.id })
      ?? MeetingAttendee(id: params.id, joined: params.joined ?? now)
    let isNew = !meeting.attendees.contains(where: { $0.id == params.id })
    let hadLeft = attendee.left != nil

    if let displayName = params.displayName { attendee.displayName = displayName }
    if let joined = params.joined { attendee.joined = joined }
    if let left = params.left { attendee.left = left }
    if let source = params.source { attendee.source = source }

    if let index = meeting.attendees.firstIndex(where: { $0.id == params.id }) {
      meeting.attendees[index] = attendee
    } else {
      meeting.attendees.append(attendee)
    }
    if let source = attendee.source {
      _ = mergeSources([source], into: &meeting)
    }

    try persist(meeting)
    if isNew {
      appendEvent(meeting.id, event: "attendee_joined", at: attendee.joined ?? now,
        attendee: attendee.id)
    }
    if !hadLeft, let left = attendee.left {
      appendEvent(meeting.id, event: "attendee_left", at: left, attendee: attendee.id)
    }
    await publish(&meeting)
    meetings[meeting.id] = meeting
    return meeting
  }

  /// `meeting.list`: live + recently-ended meetings, sorted by start.
  /// Closed history is read from disk, not the socket.
  public func list() -> [Meeting] {
    meetings.values.sorted { $0.started < $1.started }
  }

  /// `meeting.get`: a live/recent meeting, or (falling back) one read from
  /// disk.
  public func get(id: String) throws -> Meeting {
    guard let meeting = knownMeeting(id) else {
      throw MeetingRegistryError.notFound(id)
    }
    return meeting
  }

  // MARK: - Ingest stream tracking (orphan grace)

  /// A live ingest stream opened for `source` — cancels any pending grace
  /// expiry for meetings that include it.
  public func ingestStreamOpened(source: SourceID) {
    liveIngest[source, default: 0] += 1
    for meeting in meetings.values
    where meeting.state != .ended && meeting.sources.contains(source) {
      // Bump the generation: any in-flight grace timer becomes a no-op.
      graceGeneration[meeting.id, default: 0] += 1
    }
  }

  /// A live ingest stream closed for `source` — when this leaves a browser
  /// meeting with no live streams at all, its grace clock starts.
  public func ingestStreamClosed(source: SourceID) {
    let remaining = max(0, (liveIngest[source] ?? 0) - 1)
    liveIngest[source] = remaining == 0 ? nil : remaining
    for meeting in meetings.values
    where meeting.state != .ended && meeting.sources.contains(source) {
      if meeting.isBrowserMeeting && !hasLiveIngest(meeting) {
        scheduleGraceExpiry(meetingID: meeting.id)
      }
    }
  }

  private func hasLiveIngest(_ meeting: Meeting) -> Bool {
    meeting.sources.contains { (liveIngest[$0] ?? 0) > 0 }
  }

  private func scheduleGraceExpiry(meetingID: String) {
    graceGeneration[meetingID, default: 0] += 1
    let generation = graceGeneration[meetingID]!
    let wait = sleep
    let seconds = graceSeconds
    Task { [weak self] in
      await wait(seconds)
      await self?.expireIfStillOrphaned(meetingID: meetingID, generation: generation)
    }
  }

  private func expireIfStillOrphaned(meetingID: String, generation: Int) async {
    guard graceGeneration[meetingID] == generation,
      let meeting = meetings[meetingID],
      meeting.state != .ended,
      meeting.isBrowserMeeting,
      !hasLiveIngest(meeting)
    else { return }
    do {
      _ = try await end(id: meetingID, reason: .ingestIdle)
      log("meeting \(meetingID) ended: ingest idle past grace")
    } catch {
      log("meeting \(meetingID) orphan expiry failed: \(error)")
    }
  }

  // MARK: - Internals

  private func knownMeeting(_ id: String) -> Meeting? {
    if let meeting = meetings[id] { return meeting }
    return try? MeetingStore.read(meetingID: id, dataRoot: dataRoot)
  }

  /// A meeting a lifecycle verb may still mutate.
  private func liveMeeting(_ id: String) throws -> Meeting {
    guard let meeting = knownMeeting(id) else {
      throw MeetingRegistryError.notFound(id)
    }
    guard meeting.state != .ended else {
      throw MeetingRegistryError.ended(id)
    }
    return meeting
  }

  /// Closes the open interval, if any. Returns whether one was closed.
  private func closeOpenInterval(of meeting: inout Meeting, at now: Instant) -> Bool {
    guard let index = meeting.intervals.lastIndex(where: { $0.end == nil }) else {
      return false
    }
    meeting.intervals[index].end = now
    return true
  }

  private func mergeSources(_ sources: [SourceID], into meeting: inout Meeting) -> Bool {
    var changed = false
    for source in sources where !meeting.sources.contains(source) {
      meeting.sources.append(source)
      changed = true
    }
    return changed
  }

  /// One closed `SessionDescriptor` per non-empty interval: slug = the
  /// meeting UUID, trigger preserved, and the roster written into the
  /// session's `[speakers]` map (attendee `source` → `display_name`).
  private func materializeSessions(for meeting: Meeting) -> [SessionDescriptor] {
    var speakers: [String: String] = [:]
    for attendee in meeting.attendees {
      if let source = attendee.source, let name = attendee.displayName {
        speakers[source.rawValue] = name
      }
    }
    var sessions: [SessionDescriptor] = []
    for interval in meeting.intervals {
      guard let end = interval.end, interval.start < end else { continue }
      let descriptor = SessionDescriptor(
        schema: sessionSchema,
        id: "\(FilenameTimestampCodec.string(for: interval.start))_\(meeting.id)",
        slug: meeting.id,
        sources: meeting.sources,
        start: interval.start,
        end: end,
        state: .closed,
        trigger: meeting.trigger,
        speakers: speakers)
      do {
        try SessionStore.write(descriptor, dataRoot: dataRoot)
        sessions.append(descriptor)
      } catch {
        log("meeting \(meeting.id): failed to materialize session \(descriptor.id): \(error)")
      }
    }
    return sessions
  }

  private func persist(_ meeting: Meeting) throws {
    try MeetingStore.write(meeting, dataRoot: dataRoot)
  }

  /// Publishes the meeting as a revision-tagged state event, stamping the
  /// assigned revision into the object itself (result and notification carry
  /// the same `rev`).
  private func publish(_ meeting: inout Meeting) async {
    guard let bus else { return }
    let snapshot = meeting
    let rev = await bus.publishState { rev in
      var stamped = snapshot
      stamped.rev = rev
      return .meeting(stamped)
    }
    meeting.rev = rev
  }

  /// Best-effort `events.jsonl` append — never load-bearing.
  private func appendEvent(
    _ meetingID: String, event: String, at instant: Instant,
    attendee: String? = nil, title: String? = nil, reason: String? = nil
  ) {
    let entry = MeetingEventLog.Entry(
      t: ISO8601InstantCodec.format(instant), event: event, attendee: attendee,
      title: title, reason: reason)
    do {
      try MeetingEventLog.append(entry, dataRoot: dataRoot, meetingID: meetingID)
    } catch {
      log("meeting \(meetingID): events.jsonl append failed: \(error)")
    }
  }

  private static func defaultTitle(identity: MeetingIdentity?) -> String {
    guard let identity else { return "meeting" }
    return "\(identity.platform) \(identity.externalID)"
  }
}
