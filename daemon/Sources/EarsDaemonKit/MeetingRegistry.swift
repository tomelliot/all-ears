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

/// Owns the v2 **Meeting** lifecycle (`docs/specs/control-protocol.md`):
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
/// ## Capture is meeting-scoped
///
/// Recording is bounded by a meeting's existence: `meeting.start` starts
/// capture of the meeting's sources (via the injected ``startCapture`` seam,
/// which `EarsDaemon` wires to build-and-start the relevant `CaptureActor`s),
/// and `meeting.end` stops and tears them down (``stopCapture``). Browser
/// (`browser:*`) sources are driven by their ingest streams instead, so the
/// capture seams no-op on them; the daemon-side controller only manages the
/// config-declared local sources (mic, system, app) a meeting names. Pause and
/// resume remain *marks* over that recording — pausing closes the open
/// interval, resuming opens a new one — and do not stop capture.
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
    /// A new `meeting.start` for a different identity force-ended this one to
    /// hold the single-active-meeting invariant (see ``start(_:)``). One meeting
    /// ended `superseded` is one grep away from the start that killed it.
    case superseded
    /// Found `active`/`paused` on disk at boot but not chosen as the single
    /// meeting to resume — swept by ``loadFromDisk()`` and run through the
    /// normal on_end pipeline so its audio isn't stranded.
    case orphaned
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
  /// How long a browser-triggered meeting with a multi-party roster may run
  /// with no `browser:*` source before the daemon logs a loud warning
  /// (`meeting.browser_audio_missing`). 0 disables the watchdog.
  private let browserAudioWarnSeconds: Double
  /// Injectable wait, so orphan-grace tests never sleep real time.
  private let sleep: @Sendable (Double) async -> Void
  private let sessionSchema: Int
  private let onEnded: EndedHook?
  /// `[earsd.meetings].local_sources`: locally-captured source ids folded into
  /// every *browser-triggered* meeting at start, so the host's own audio is
  /// transcribed alongside the extension's per-participant streams. Filtered
  /// through ``knownSourceIDs`` at inject time so an id the daemon isn't
  /// capturing is skipped rather than failing `transcribe --meeting`.
  private let localBrowserSources: [SourceID]
  /// Live lookup of the daemon's current source ids — the guard that keeps a
  /// configured local source from being attached to a meeting when it doesn't
  /// exist. `{ [] }` (the default) injects nothing, matching a registry built
  /// with no local sources.
  private let knownSourceIDs: @Sendable () async -> Set<SourceID>
  /// Starts capture for a meeting's sources (build-and-start the relevant
  /// `CaptureActor`s), keyed by meeting id so concurrent meetings sharing a
  /// source are ref-counted daemon-side. Called on `meeting.start` and on
  /// restart recovery for a still-active meeting. `EarsDaemon` supplies the
  /// real implementation; the default no-op keeps registry-only tests (no
  /// daemon) unchanged.
  private let startCapture: @Sendable (String, [SourceID]) async -> Void
  /// Stops and tears down capture for a meeting's sources, released daemon-side
  /// by the same ref-count. Called on `meeting.end` (before the ended hook, so
  /// each source's final chunk is flushed to disk before transcription runs).
  private let stopCapture: @Sendable (String, [SourceID]) async -> Void

  /// Live (active/paused) and recently-ended meetings, keyed by id. Ended
  /// meetings from *before* this boot stay on disk only.
  private var meetings: [String: Meeting] = [:]
  /// `(platform, externalID)` → live meeting id, for `meeting.start`'s
  /// idempotency. Ended meetings drop out — rejoining an ended meeting's
  /// identity starts a fresh one.
  private var byIdentity: [MeetingIdentity: String] = [:]
  /// Live ingest streams per source, fed by `EarsDaemon`.
  private var liveIngest: [SourceID: Int] = [:]
  /// Membership tags from `ingest.open` that arrived before their identity's
  /// `meeting.start` — claimed by the meeting that declares the identity,
  /// dropped when the source's last live stream closes first.
  private var pendingIngestLinks: [SourceID: MeetingIdentity] = [:]
  /// Grace-timer invalidation: a scheduled expiry only fires if the
  /// meeting's generation still matches (a re-opened stream bumps it).
  private var graceGeneration: [String: Int] = [:]
  /// Meetings the browser-audio watchdog has already warned about (one
  /// warning per meeting); cleared on end.
  private var browserAudioWarned: Set<String> = []
  /// Meetings with a browser-audio check already in flight, so roster churn
  /// arms at most one timer at a time.
  private var browserAudioCheckPending: Set<String> = []

  public init(
    dataRoot: URL,
    clock: any NowProviding = SystemClock(),
    makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
    bus: EventBus? = nil,
    graceSeconds: Double = 120,
    browserAudioWarnSeconds: Double = 120,
    sleep: @escaping @Sendable (Double) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    sessionSchema: Int = ActorContracts.sessionSchemaVersion,
    onEnded: EndedHook? = nil,
    localBrowserSources: [SourceID] = [],
    knownSourceIDs: @escaping @Sendable () async -> Set<SourceID> = { [] },
    startCapture: @escaping @Sendable (String, [SourceID]) async -> Void = { _, _ in },
    stopCapture: @escaping @Sendable (String, [SourceID]) async -> Void = { _, _ in },
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.makeID = makeID
    self.bus = bus
    self.graceSeconds = graceSeconds
    self.browserAudioWarnSeconds = browserAudioWarnSeconds
    self.sleep = sleep
    self.sessionSchema = sessionSchema
    self.onEnded = onEnded
    self.localBrowserSources = localBrowserSources
    self.knownSourceIDs = knownSourceIDs
    self.startCapture = startCapture
    self.stopCapture = stopCapture
    self.log = log
  }

  // MARK: - Startup

  /// Reloads meetings from disk — called once at daemon start. The
  /// single-active-meeting invariant applies here too: at most **one** meeting
  /// resumes. The most-recently-started live record is treated as the genuine
  /// in-progress call (a mid-meeting daemon restart) and resumes as-is —
  /// including capture of its (config-declared) sources, so a restart mid-call
  /// keeps recording. Every *other* `active`/`paused` record on disk is a stale
  /// leak from an earlier instance (the daemon died without a `meeting.end`) and
  /// is ended as ``EndReason/orphaned`` through the normal on_end pipeline, so
  /// its audio is materialized rather than stranded — and can never claim
  /// capture actors ahead of a real meeting (#19/#24).
  ///
  /// A resumed *browser* meeting whose streams don't return starts its orphan
  /// grace clock from daemon boot, so even the survivor converges to `ended` if
  /// it's actually dead.
  public func loadFromDisk() async {
    let live = MeetingStore.readAll(
      dataRoot: dataRoot,
      onSkip: { [log] id, error in log("meeting registry: skipping meetings/\(id): \(error)") }
    ).filter { $0.state != .ended }

    // The survivor: the most-recently-started live meeting. Ties (identical
    // `started`) resolve by id for determinism.
    let survivor = live.max {
      ($0.started, $0.id) < ($1.started, $1.id)
    }

    for meeting in live where meeting.id != survivor?.id {
      log(
        "boot: orphaning stale meeting \(meeting.id) identity=\(identityLabel(meeting)) "
          + "state=\(meeting.state.rawValue) age=\(ageSeconds(meeting)) "
          + "lastActivity=\(ISO8601InstantCodec.format(lastActivity(meeting))) "
          + "sources=\(sourceLabel(meeting)) rule=not-latest-active")
      meetings[meeting.id] = meeting
      if let identity = meeting.identity {
        byIdentity[identity] = meeting.id
      }
      do {
        _ = try await end(id: meeting.id, reason: .orphaned)
      } catch {
        log("boot: orphaning stale meeting \(meeting.id) failed: \(error)")
      }
    }

    guard let survivor else { return }
    log(
      "boot: resuming meeting \(survivor.id) identity=\(identityLabel(survivor)) "
        + "state=\(survivor.state.rawValue) age=\(ageSeconds(survivor)) "
        + "lastActivity=\(ISO8601InstantCodec.format(lastActivity(survivor))) "
        + "sources=\(sourceLabel(survivor)) rule=latest-active")
    meetings[survivor.id] = survivor
    if let identity = survivor.identity {
      byIdentity[identity] = survivor.id
    }
    if survivor.isBrowserMeeting {
      scheduleGraceExpiry(meetingID: survivor.id)
    }
    if survivor.state == .active {
      log("boot: resuming capture for meeting \(survivor.id) sources=\(sourceLabel(survivor))")
      await startCapture(survivor.id, survivor.sources)
    }
  }

  // MARK: - Lifecycle verbs

  /// `meeting.start`. Idempotent on `identity`: re-declaring a live meeting
  /// returns its current state (merging any newly-named sources) — the
  /// recovery path for service-worker eviction and daemon restart alike.
  /// Without an identity this creates a manual meeting.
  ///
  /// ## Single active meeting invariant
  ///
  /// A start for a *new* identity (or a manual start) **supersedes** any meeting
  /// still live: one user, one Mac, one call at a time. The superseded meeting
  /// is run through its full end pipeline (interval close, session
  /// materialization, on_end, capture teardown — ``EndReason/superseded``)
  /// *before* the successor is created, so the new meeting rebuilds its capture
  /// actors against its own directory and the wrong-directory hazard (#19)
  /// becomes structurally impossible: at most one active meeting means exactly
  /// one legal meeting directory for any capture actor at any moment. A
  /// duplicate/racing start for the *same* identity is idempotent (handled
  /// above) and never supersedes itself, which absorbs extension reconnect churn
  /// (reconnects carry the same identity tag).
  public func start(_ params: MeetingStartParams) async throws -> Meeting {
    if let identity = params.identity,
      let existingID = byIdentity[identity],
      var existing = meetings[existingID],
      existing.state != .ended
    {
      let merged = mergeSources(params.sources + claimPendingLinks(for: identity), into: &existing)
      if merged {
        try persist(existing)
        await publish(&existing)
      }
      meetings[existing.id] = existing
      log(
        "meeting.start idempotent re-declare: meeting=\(existing.id) "
          + "identity=\(identityLabel(existing)) merged_sources=\(merged) "
          + "sources=\(sourceLabel(existing))")
      // Idempotent daemon-side: re-declaring the same meeting only starts
      // capture for sources it hasn't already claimed.
      await startCapture(existing.id, existing.sources)
      return existing
    }

    let now = clock.now()
    let identity = params.identity
    let trigger = params.trigger ?? .manual

    // Enforce the single-active-meeting invariant: supersede every meeting still
    // live before creating this one. Under the invariant there is at most one,
    // but sweep all defensively (sorted for a deterministic, oldest-first log).
    let newIdentityLabel = identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
    let toSupersede = meetings.values
      .filter { $0.state != .ended }
      .sorted { ($0.started, $0.id) < ($1.started, $1.id) }
    for old in toSupersede {
      log(
        "meeting.start supersede: new_meeting_identity=\(newIdentityLabel) "
          + "superseded_meeting=\(old.id) superseded_identity=\(identityLabel(old)) "
          + "age=\(ageSeconds(old)) lastActivity=\(ISO8601InstantCodec.format(lastActivity(old))) "
          + "reason=superseded")
      do {
        _ = try await end(id: old.id, reason: .superseded)
      } catch {
        log("meeting.start supersede of \(old.id) failed: \(error)")
      }
    }
    // Tagged ingest streams that opened before this start claim their
    // membership now (see `link(source:to:)`).
    var declared = params.sources
    if let identity {
      for source in claimPendingLinks(for: identity) where !declared.contains(source) {
        declared.append(source)
      }
    }
    var meeting = Meeting(
      id: makeID(),
      identity: identity,
      title: params.title ?? Self.defaultTitle(identity: identity),
      state: .active,
      started: now,
      intervals: [MeetingInterval(start: now)],
      sources: await initialSources(declared: declared, trigger: trigger),
      trigger: trigger)
    try persist(meeting)
    appendEvent(meeting.id, event: "started", at: now)
    appendEvent(meeting.id, event: "interval_opened", at: now)
    await publish(&meeting)
    meetings[meeting.id] = meeting
    if let identity {
      byIdentity[identity] = meeting.id
    }
    log(
      "meeting.start: meeting=\(meeting.id) identity=\(newIdentityLabel) "
        + "trigger=\(trigger.rawValue) sources=\(sourceLabel(meeting)) "
        + "superseded=\(toSupersede.count)")
    await startCapture(meeting.id, meeting.sources)
    if trigger == .browserExtension {
      scheduleBrowserAudioCheck(meetingID: meeting.id)
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

    logRosterSummary(meeting)
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
    browserAudioWarned.remove(meeting.id)
    browserAudioCheckPending.remove(meeting.id)

    // Stop and tear down capture before the ended hook runs, so each source's
    // in-progress chunk is flushed and indexed to disk before transcription
    // reads it. Browser sources are already stopped by their ingest close; the
    // controller no-ops on those and stops the meeting's local sources.
    await stopCapture(meeting.id, meeting.sources)

    if let onEnded {
      await onEnded(meeting, sessions)
    }
    return meeting
  }

  /// Records that this meeting's transcript completed **successfully** at
  /// `at` — the durable marker the retention sweeper keys off. Idempotent; a
  /// later successful re-transcription moves the marker forward. A no-op for an
  /// unknown meeting (nothing to mark).
  public func markTranscriptCompleted(id: String, at: Instant) {
    guard var meeting = knownMeeting(id) else { return }
    meeting.transcriptCompleted = at
    do {
      try persist(meeting)
    } catch {
      log("meeting \(id): persisting transcript-completed marker failed: \(error)")
    }
    meetings[meeting.id] = meeting
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

    // Trace every upsert so an empty `display_name`/`source` in meeting.toml is
    // attributable to "never sent" (recv_* is `-` on every upsert for this id)
    // vs "sent but not merged" (recv_* carried a value the stored field didn't
    // pick up) — issue #23's debug-logging requirement.
    log(
      "meeting.attendee upsert: meeting=\(meeting.id) attendee=\(params.id) new=\(isNew) "
        + "recv_display_name=\(logField(params.displayName)) "
        + "recv_source=\(logField(params.source?.rawValue)) "
        + "stored_display_name=\(logField(attendee.displayName)) "
        + "stored_source=\(logField(attendee.source?.rawValue))")

    try persist(meeting)
    if isNew {
      appendEvent(
        meeting.id, event: "attendee_joined", at: attendee.joined ?? now,
        attendee: attendee.id)
    }
    if !hadLeft, let left = attendee.left {
      appendEvent(meeting.id, event: "attendee_left", at: left, attendee: attendee.id)
    }
    await publish(&meeting)
    meetings[meeting.id] = meeting
    // A roster event is the watchdog's re-arm signal: a guest who joins (or
    // gets named) mid-meeting starts a fresh browser-audio clock.
    if meeting.trigger == .browserExtension && meeting.state != .ended {
      scheduleBrowserAudioCheck(meetingID: meeting.id)
    }
    return meeting
  }

  /// `meeting.list`: live + recently-ended meetings, sorted by start.
  /// Closed history is read from disk, not the socket.
  public func list() -> [Meeting] {
    meetings.values.sorted { $0.started < $1.started }
  }

  /// The live meeting id declared under `identity`, or `nil` when no live
  /// meeting has it — how `EarsDaemon.openIngestSource` resolves an ingest
  /// stream's membership tag to the meeting directory its audio lands in.
  public func meetingID(for identity: MeetingIdentity) -> String? {
    byIdentity[identity]
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
  ///
  /// A non-nil `meeting` is the client's membership tag: the daemon joins the
  /// source into that identity's live meeting itself (stashing the link until
  /// `meeting.start` arrives, if the open raced ahead of it). This is what
  /// keeps the ingest-idle grace policy sound when the client's own
  /// `meeting.attendee` source upserts never arrive — an MV3 service worker
  /// respawned mid-call has no meeting state to upsert from, but the tab's
  /// PCM keeps flowing with the tag attached.
  public func ingestStreamOpened(source: SourceID, meeting identity: MeetingIdentity? = nil) async {
    liveIngest[source, default: 0] += 1
    if let identity {
      await link(source: source, to: identity)
    }

    // Scope the grace cancellation to the meeting this open's identity tag
    // resolves to — NOT every non-ended meeting whose roster happens to include
    // the (slot-style, non-unique) `source` label. Bumping the generation for
    // unrelated meetings sharing a `browser:meet:speaker-N` slot is exactly what
    // kept stale meetings perpetually alive (#24). With no tag, fall back to the
    // meetings that name the source (at most one under the single-active
    // invariant).
    let resolvedIdentity = identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
    let resolvedMeetings: [String]
    if let identity, let id = byIdentity[identity] {
      resolvedMeetings = [id]
    } else {
      resolvedMeetings = meetings.values
        .filter { $0.state != .ended && $0.sources.contains(source) }
        .map(\.id)
    }
    for id in resolvedMeetings {
      // Bump the generation: any in-flight grace timer becomes a no-op.
      graceGeneration[id, default: 0] += 1
      log(
        "grace cancelled: meeting=\(id) cause=ingest.open source=\(source.rawValue) "
          + "resolved_identity=\(resolvedIdentity) generation=\(graceGeneration[id]!)")
    }
  }

  /// A live ingest stream closed for `source` — when this leaves a browser
  /// meeting with no live streams at all, its grace clock starts.
  public func ingestStreamClosed(source: SourceID) {
    let remaining = max(0, (liveIngest[source] ?? 0) - 1)
    liveIngest[source] = remaining == 0 ? nil : remaining
    if remaining == 0 {
      // A tag whose stream died before its meeting.start ever arrived links
      // nothing — a later meeting must not adopt a source that isn't flowing.
      pendingIngestLinks[source] = nil
    }
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

  /// Daemon-side membership: joins `source` into the live meeting declared
  /// under `identity`, or stashes the link for `start` to claim when the
  /// `ingest.open` raced ahead of the `meeting.start`.
  private func link(source: SourceID, to identity: MeetingIdentity) async {
    guard let id = byIdentity[identity], var meeting = meetings[id], meeting.state != .ended
    else {
      pendingIngestLinks[source] = identity
      return
    }
    guard mergeSources([source], into: &meeting) else { return }
    do {
      try persist(meeting)
    } catch {
      log(
        "meeting \(meeting.id): persisting ingest-linked source \(source.rawValue) failed: \(error)"
      )
    }
    await publish(&meeting)
    meetings[meeting.id] = meeting
  }

  /// Claims (and clears) every pending ingest link stashed for `identity`,
  /// sorted for deterministic source order.
  private func claimPendingLinks(for identity: MeetingIdentity) -> [SourceID] {
    let claimed = pendingIngestLinks.filter { $0.value == identity }.keys
      .sorted { $0.rawValue < $1.rawValue }
    for source in claimed { pendingIngestLinks[source] = nil }
    return claimed
  }

  // MARK: - Browser-audio watchdog

  /// Arm one browser-audio check `browserAudioWarnSeconds` from now, unless
  /// one is already pending. Armed at `meeting.start` and re-armed by every
  /// attendee upsert (a guest who joins mid-meeting restarts the clock), so
  /// there is no self-rescheduling loop — each check either warns, or waits
  /// for the next roster event to arm the next one.
  ///
  /// The 2026-07-24 Brivo call (browser/dev/captures/
  /// 2026-07-24-meet-collections-drift.md) ran 21 minutes with the extension's
  /// control channel healthy — meeting started, both names on the roster —
  /// while not one byte of remote audio arrived: Meet had migrated call audio
  /// off the RTP path the extension taps, silently. The daemon-visible shape
  /// of that failure is precise: a browser-triggered meeting whose roster
  /// proves a multi-party call (≥ 2 named attendees) but whose sources never
  /// gain a single `browser:*` entry. This watchdog makes that shape loud.
  private func scheduleBrowserAudioCheck(meetingID: String) {
    guard browserAudioWarnSeconds > 0,
      !browserAudioWarned.contains(meetingID),
      !browserAudioCheckPending.contains(meetingID)
    else { return }
    browserAudioCheckPending.insert(meetingID)
    let wait = sleep
    let seconds = browserAudioWarnSeconds
    Task { [weak self] in
      await wait(seconds)
      await self?.checkBrowserAudio(meetingID: meetingID)
    }
  }

  private func checkBrowserAudio(meetingID: String) {
    browserAudioCheckPending.remove(meetingID)
    guard let meeting = meetings[meetingID],
      meeting.state != .ended,
      meeting.trigger == .browserExtension,
      !browserAudioWarned.contains(meetingID)
    else { return }
    if meeting.sources.contains(where: { $0.sourceClass == .browser }) {
      // The extension delivered at least one per-participant stream; a stream
      // that later goes dead is CaptureActor's dry-spell watchdog's job.
      return
    }
    let namedAttendees = meeting.attendees.filter { !($0.displayName ?? "").isEmpty }.count
    // Fewer than 2 names doesn't prove a multi-party call (guest may still be
    // in the lobby) — stay quiet; the upsert that names them re-arms the check.
    guard namedAttendees >= 2 else { return }
    browserAudioWarned.insert(meetingID)
    log(
      "⚠ meeting.browser_audio_missing: meeting=\(meetingID) "
        + "named_attendees=\(namedAttendees) age=\(ageSeconds(meeting))s — "
        + "roster shows a multi-party call but no browser:* audio source ever opened; "
        + "remote participants are NOT being recorded "
        + "(extension audio path down — see "
        + "browser/dev/captures/2026-07-24-meet-collections-drift.md)")
  }

  private func scheduleGraceExpiry(meetingID: String) {
    graceGeneration[meetingID, default: 0] += 1
    let generation = graceGeneration[meetingID]!
    let deadline = clock.now().advanced(by: graceSeconds)
    log(
      "grace scheduled: meeting=\(meetingID) "
        + "deadline=\(ISO8601InstantCodec.format(deadline)) generation=\(generation)")
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
    else {
      log(
        "grace expiry no-op: meeting=\(meetingID) generation=\(generation) "
          + "current_generation=\(graceGeneration[meetingID].map(String.init) ?? "-")")
      return
    }
    log("grace expiry firing: meeting=\(meetingID) generation=\(generation) reason=ingest-idle")
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

  /// A new meeting's starting source list: the client-declared sources, plus
  /// (for browser-triggered meetings only) the configured ``localBrowserSources``
  /// that the daemon is actually capturing right now — the host's own mic
  /// joins the meeting so `transcribe --meeting` covers both sides. Non-browser
  /// (manual/CLI) meetings are left exactly as declared; a CLI caller names
  /// its own sources. Declared sources keep their order and precede the
  /// injected ones; duplicates are dropped.
  private func initialSources(declared: [SourceID], trigger: TriggerKind) async -> [SourceID] {
    guard trigger == .browserExtension, !localBrowserSources.isEmpty else {
      return declared
    }
    let known = await knownSourceIDs()
    var sources = declared
    for source in localBrowserSources
    where known.contains(source) && !sources.contains(source) {
      sources.append(source)
    }
    return sources
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

  /// Renders an optional string for a log line: the quoted value, or `-` for
  /// nil/empty — so "field absent" and "field present" read distinctly.
  private func logField(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "-" }
    return "\"\(value)\""
  }

  /// At meeting end, log which attendees resolved a name and a source and which
  /// are still unresolved (name and/or source missing). This makes an
  /// unresolved attendee an explicit, greppable fact rather than a silent empty
  /// string in meeting.toml (issue #23's acceptance criterion + roster-summary
  /// logging requirement).
  private func logRosterSummary(_ meeting: Meeting) {
    let withName = meeting.attendees.filter { !($0.displayName ?? "").isEmpty }.count
    let withSource = meeting.attendees.filter { $0.source != nil }.count
    let unresolved = meeting.attendees
      .filter { ($0.displayName ?? "").isEmpty || $0.source == nil }
      .map { attendee in
        let hasName = !(attendee.displayName ?? "").isEmpty
        let hasSource = attendee.source != nil
        return "\(attendee.id)(name=\(hasName ? "yes" : "no"),source=\(hasSource ? "yes" : "no"))"
      }
    log(
      "meeting.end roster summary: meeting=\(meeting.id) attendees=\(meeting.attendees.count) "
        + "with_name=\(withName) with_source=\(withSource) "
        + "unresolved=\(unresolved.isEmpty ? "-" : unresolved.joined(separator: ","))")
  }

  private static func defaultTitle(identity: MeetingIdentity?) -> String {
    guard let identity else { return "meeting" }
    return "\(identity.platform) \(identity.externalID)"
  }

  // MARK: - Log helpers

  /// `platform:external_id`, or `-` for a manual meeting — a stable, greppable
  /// identity token for the supersede/boot logs.
  private func identityLabel(_ meeting: Meeting) -> String {
    meeting.identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
  }

  /// A comma-joined source list, or `-` when empty.
  private func sourceLabel(_ meeting: Meeting) -> String {
    meeting.sources.isEmpty ? "-" : meeting.sources.map(\.rawValue).joined(separator: ",")
  }

  /// Whole seconds since this meeting started, at the current clock — how a
  /// weeks-old "active" meeting reads as anomalous in the boot/supersede logs.
  private func ageSeconds(_ meeting: Meeting) -> Int {
    Int(clock.now().interval(since: meeting.started))
  }

  /// The most recent interval boundary (or `started` if none) — the meeting's
  /// last observable activity, surfaced alongside age in the supersede/boot logs.
  private func lastActivity(_ meeting: Meeting) -> Instant {
    var latest = meeting.started
    for interval in meeting.intervals {
      latest = max(latest, interval.start)
      if let end = interval.end {
        latest = max(latest, end)
      }
    }
    return latest
  }
}
