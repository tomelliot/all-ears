import EarsCore
import EarsDataStore
import Foundation

/// Errors surfaced by ``SessionRegistry``, mapped 1:1 onto the v2 wire's
/// stable error codes by `ControlServer`.
public enum SessionRegistryError: Error, Sendable, Hashable {
  /// No session (live or on disk) has this id → `session_not_found`.
  case notFound(String)
  /// A lifecycle verb targeted a session that has already ended →
  /// `session_ended`.
  case ended(String)
  /// `session.rename`'s `if_rev` didn't match the session's current
  /// revision → `conflict`.
  case conflict(String)
}

/// Owns the v2 **Session** lifecycle (`docs/specs/control-protocol.md`):
/// start (idempotent on identity), pause/resume as interval marks, the
/// attendee roster, rename, end, and the orphaned-session grace policy.
/// This is what v1's client-side session tracker becomes — the daemon, not
/// any frontend, owns the state machine.
///
/// ## Persistence
///
/// Every mutation writes `sessions/<uuid>/session.toml` (schema 3) atomically
/// via ``SessionStore`` and appends the domain event to the session's
/// `events.jsonl` (best-effort — the timeline is for disk consumers, never
/// load-bearing for protocol sync). Active/paused sessions reload at daemon
/// start via ``loadFromDisk()``, which is what lets a session survive a
/// daemon restart.
///
/// ## Capture is session-scoped
///
/// Recording is bounded by a session's existence: `session.start` starts
/// capture of the session's sources (via the injected ``startCapture`` seam,
/// which `EarsDaemon` wires to build-and-start the relevant `CaptureActor`s),
/// and `session.end` stops and tears them down (``stopCapture``). Browser
/// (`browser:*`) sources are driven by their ingest streams instead, so the
/// capture seams no-op on them; the daemon-side controller only manages the
/// config-declared local sources (mic, system, app) a session names. Pause and
/// resume remain *marks* over that recording — pausing closes the open
/// interval, resuming opens a new one — and do not stop capture.
///
/// ## Orphaned sessions
///
/// Browser sessions (any `browser:*` source) auto-end with
/// `reason = "ingest-idle"` once their last live ingest stream has been
/// closed for `graceSeconds` with no re-open — `EarsDaemon` feeds
/// ``ingestStreamOpened(source:session:)``/``ingestStreamClosed(source:session:)``
/// from the ingest WebSocket. Manual sessions are never auto-ended: the daemon
/// records, it doesn't decide.
public actor SessionRegistry {
  /// Why a session ended, recorded in `events.jsonl`'s `ended` line.
  public enum EndReason: String, Sendable {
    /// An explicit `session.end`.
    case client
    /// The orphan grace timer fired.
    case ingestIdle = "ingest-idle"
    /// A new `session.start` for a different identity force-ended this one to
    /// hold the single-active-session invariant (see ``start(_:)``). One session
    /// ended `superseded` is one grep away from the start that killed it.
    case superseded
    /// Found `active`/`paused` on disk at boot but not chosen as the single
    /// session to resume — swept by ``loadFromDisk()`` and run through the
    /// normal on_end pipeline so its audio isn't stranded.
    case orphaned
  }

  /// Called after every session end with the final session — the seam
  /// ``EarsDaemon`` hangs auto-transcription (`transcribe --session <id>`)
  /// off.
  public typealias EndedHook = @Sendable (Session) async -> Void

  private let dataRoot: URL
  private let clock: any NowProviding
  /// Mints a new session id — injected so tests get deterministic ids.
  private let makeID: @Sendable () -> String
  /// The live-feed publisher (revision assignment included); `nil` publishes
  /// nothing.
  private let bus: EventBus?
  private let log: @Sendable (String) -> Void
  /// `[earsd.sessions].ingest_close_grace_s`.
  private let graceSeconds: Double
  /// How long a browser-triggered session with a multi-party roster may run
  /// with no `browser:*` source before the daemon logs a loud warning
  /// (`session.browser_audio_missing`). 0 disables the watchdog.
  private let browserAudioWarnSeconds: Double
  /// Injectable wait, so orphan-grace tests never sleep real time.
  private let sleep: @Sendable (Double) async -> Void
  private let onEnded: EndedHook?
  /// `[earsd.sessions].local_sources`: locally-captured source ids folded into
  /// every *browser-triggered* session at start, so the host's own audio is
  /// transcribed alongside the extension's per-participant streams. Filtered
  /// through ``knownSourceIDs`` at inject time so an id the daemon isn't
  /// capturing is skipped rather than failing `transcribe --session`.
  private let localBrowserSources: [SourceID]
  /// Live lookup of the daemon's current source ids — the guard that keeps a
  /// configured local source from being attached to a session when it doesn't
  /// exist. `{ [] }` (the default) injects nothing, matching a registry built
  /// with no local sources.
  private let knownSourceIDs: @Sendable () async -> Set<SourceID>
  /// Starts capture for a session's sources (build-and-start the relevant
  /// `CaptureActor`s), keyed by session id so concurrent sessions sharing a
  /// source are ref-counted daemon-side. Called on `session.start` and on
  /// restart recovery for a still-active session. `EarsDaemon` supplies the
  /// real implementation; the default no-op keeps registry-only tests (no
  /// daemon) unchanged.
  private let startCapture: @Sendable (String, [SourceID]) async -> Void
  /// Stops and tears down capture for a session's sources, released daemon-side
  /// by the same ref-count. Called on `session.end` (before the ended hook, so
  /// each source's final chunk is flushed to disk before transcription runs).
  private let stopCapture: @Sendable (String, [SourceID]) async -> Void

  /// Live (active/paused) and recently-ended sessions, keyed by id. Ended
  /// sessions from *before* this boot stay on disk only.
  private var sessions: [String: Session] = [:]
  /// `(platform, externalID)` → live session id, for `session.start`'s
  /// idempotency. Ended sessions drop out — rejoining an ended session's
  /// identity starts a fresh one.
  private var byIdentity: [SessionIdentity: String] = [:]
  /// Live ingest streams per source, fed by `EarsDaemon`.
  private var liveIngest: [SourceID: Int] = [:]
  /// Membership tags from `ingest.open` that arrived before their identity's
  /// `session.start` — claimed by the session that declares the identity,
  /// dropped when the source's last live stream closes first.
  private var pendingIngestLinks: [SourceID: SessionIdentity] = [:]
  /// Grace-timer invalidation: a scheduled expiry only fires if the
  /// session's generation still matches (a re-opened stream bumps it).
  private var graceGeneration: [String: Int] = [:]
  /// Sessions the browser-audio watchdog has already warned about (one
  /// warning per session); cleared on end.
  private var browserAudioWarned: Set<String> = []
  /// Sessions with a browser-audio check already in flight, so roster churn
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
    self.onEnded = onEnded
    self.localBrowserSources = localBrowserSources
    self.knownSourceIDs = knownSourceIDs
    self.startCapture = startCapture
    self.stopCapture = stopCapture
    self.log = log
  }

  // MARK: - Startup

  /// Reloads sessions from disk — called once at daemon start. The
  /// single-active-session invariant applies here too: at most **one** session
  /// resumes. The most-recently-started live record is treated as the genuine
  /// in-progress call (a mid-session daemon restart) and resumes as-is —
  /// including capture of its (config-declared) sources, so a restart mid-call
  /// keeps recording. Every *other* `active`/`paused` record on disk is a stale
  /// leak from an earlier instance (the daemon died without a `session.end`) and
  /// is ended as ``EndReason/orphaned`` through the normal on_end pipeline, so
  /// its audio is transcribed rather than stranded — and can never claim
  /// capture actors ahead of a real session (#19/#24).
  ///
  /// A resumed *browser* session whose streams don't return starts its orphan
  /// grace clock from daemon boot, so even the survivor converges to `ended` if
  /// it's actually dead.
  ///
  /// A `session.toml` that exists but doesn't parse is **repaired**, not just
  /// skipped — see ``repairCorruptSession(id:error:)``: skipping alone left
  /// the directory's audio invisible to the retention sweeper (which reads
  /// the same descriptors) and therefore stranded forever.
  public func loadFromDisk() async {
    var corrupt: [(id: String, error: Error)] = []
    let live = SessionStore.readAll(
      dataRoot: dataRoot,
      onSkip: { id, error in corrupt.append((id, error)) }
    ).filter { $0.state != .ended }

    for (id, error) in corrupt {
      repairCorruptSession(id: id, error: error)
    }

    // The survivor: the most-recently-started live session. Ties (identical
    // `started`) resolve by id for determinism.
    let survivor = live.max {
      ($0.started, $0.id) < ($1.started, $1.id)
    }

    for session in live where session.id != survivor?.id {
      log(
        "boot: orphaning stale session \(session.id) identity=\(identityLabel(session)) "
          + "state=\(session.state.rawValue) age=\(ageSeconds(session)) "
          + "lastActivity=\(ISO8601InstantCodec.format(lastActivity(session))) "
          + "sources=\(sourceLabel(session)) rule=not-latest-active")
      sessions[session.id] = session
      if let identity = session.identity {
        byIdentity[identity] = session.id
      }
      do {
        _ = try await end(id: session.id, reason: .orphaned)
      } catch {
        log("boot: orphaning stale session \(session.id) failed: \(error)")
      }
    }

    guard let survivor else { return }
    log(
      "boot: resuming session \(survivor.id) identity=\(identityLabel(survivor)) "
        + "state=\(survivor.state.rawValue) age=\(ageSeconds(survivor)) "
        + "lastActivity=\(ISO8601InstantCodec.format(lastActivity(survivor))) "
        + "sources=\(sourceLabel(survivor)) rule=latest-active")
    sessions[survivor.id] = survivor
    if let identity = survivor.identity {
      byIdentity[identity] = survivor.id
    }
    if survivor.isBrowserSession {
      scheduleGraceExpiry(sessionID: survivor.id)
    }
    if survivor.state == .active {
      log("boot: resuming capture for session \(survivor.id) sources=\(sourceLabel(survivor))")
      await startCapture(survivor.id, survivor.sources)
    }
  }

  /// Quarantines an unparseable `session.toml` and writes a minimal **ended**
  /// record in its place, so the directory's audio re-enters retention.
  ///
  /// The unreadable original is preserved beside it as `session.toml.corrupt`
  /// (replacing any earlier quarantine) for diagnosis. The synthesized record
  /// is deliberately minimal — this boot's instant for `started`/`ended`, no
  /// identity, no sources — because nothing in the corrupt file can be
  /// trusted; its one job is to exist and be `ended`, which is what lets the
  /// eviction sweeper delete `sources/` at `ended + max_audio_age_seconds`
  /// instead of never. The repair is recorded in the session's `warnings`, so
  /// `session list`/`session.get` show it where a user looks.
  private func repairCorruptSession(id: String, error: Error) {
    let now = clock.now()
    let tomlURL = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: id)
    let quarantineURL = tomlURL.appendingPathExtension("corrupt")
    do {
      if FileManager.default.fileExists(atPath: quarantineURL.path) {
        try FileManager.default.removeItem(at: quarantineURL)
      }
      try FileManager.default.moveItem(at: tomlURL, to: quarantineURL)
    } catch {
      log("boot: quarantining corrupt sessions/\(id)/session.toml failed: \(error)")
      return
    }
    let repaired = Session(
      id: id,
      title: "recovered session",
      state: .ended,
      started: now,
      ended: now,
      warnings: [
        "session.toml was unreadable at boot (\(error)); the original is preserved as "
          + "session.toml.corrupt and this minimal record re-entered the session into retention"
      ])
    do {
      try persist(repaired)
      log(
        "boot: repaired corrupt sessions/\(id)/session.toml — original preserved as "
          + "session.toml.corrupt, minimal ended record written (was: \(error))")
    } catch {
      log("boot: rewriting repaired sessions/\(id)/session.toml failed: \(error)")
    }
  }

  // MARK: - Lifecycle verbs

  /// `session.start`. Idempotent on `identity`: re-declaring a live session
  /// returns its current state (merging any newly-named sources) — the
  /// recovery path for service-worker eviction and daemon restart alike.
  /// Without an identity this creates a manual session.
  ///
  /// ## Single active session invariant
  ///
  /// A start for a *new* identity (or a manual start) **supersedes** any session
  /// still live: one user, one Mac, one call at a time. The superseded session
  /// is run through its full end pipeline (interval close, on_end, capture
  /// teardown — ``EndReason/superseded``)
  /// *before* the successor is created, so the new session rebuilds its capture
  /// actors against its own directory and the wrong-directory hazard (#19)
  /// becomes structurally impossible: at most one active session means exactly
  /// one legal session directory for any capture actor at any moment. A
  /// duplicate/racing start for the *same* identity is idempotent (handled
  /// above) and never supersedes itself, which absorbs extension reconnect churn
  /// (reconnects carry the same identity tag).
  public func start(_ params: SessionStartParams) async throws -> Session {
    if let identity = params.identity,
      let existingID = byIdentity[identity],
      var existing = sessions[existingID],
      existing.state != .ended
    {
      let merged = mergeSources(params.sources + claimPendingLinks(for: identity), into: &existing)
      if merged {
        try persist(existing)
        await publish(&existing)
      }
      sessions[existing.id] = existing
      log(
        "session.start idempotent re-declare: session=\(existing.id) "
          + "identity=\(identityLabel(existing)) merged_sources=\(merged) "
          + "sources=\(sourceLabel(existing))")
      // Idempotent daemon-side: re-declaring the same session only starts
      // capture for sources it hasn't already claimed.
      await startCapture(existing.id, existing.sources)
      return existing
    }

    let now = clock.now()
    let identity = params.identity
    let trigger = params.trigger ?? .manual

    // Enforce the single-active-session invariant: supersede every session still
    // live before creating this one. Under the invariant there is at most one,
    // but sweep all defensively (sorted for a deterministic, oldest-first log).
    let newIdentityLabel = identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
    let toSupersede = sessions.values
      .filter { $0.state != .ended }
      .sorted { ($0.started, $0.id) < ($1.started, $1.id) }
    for old in toSupersede {
      log(
        "session.start supersede: new_session_identity=\(newIdentityLabel) "
          + "superseded_session=\(old.id) superseded_identity=\(identityLabel(old)) "
          + "age=\(ageSeconds(old)) lastActivity=\(ISO8601InstantCodec.format(lastActivity(old))) "
          + "reason=superseded")
      do {
        _ = try await end(id: old.id, reason: .superseded)
      } catch {
        log("session.start supersede of \(old.id) failed: \(error)")
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
    var session = Session(
      id: makeID(),
      identity: identity,
      title: params.title ?? Session.defaultTitle(identity: identity, started: now),
      state: .active,
      started: now,
      intervals: [SessionInterval(start: now)],
      sources: await initialSources(declared: declared, trigger: trigger),
      trigger: trigger)
    try persist(session)
    appendEvent(session.id, event: "started", at: now)
    appendEvent(session.id, event: "interval_opened", at: now)
    await publish(&session)
    sessions[session.id] = session
    if let identity {
      byIdentity[identity] = session.id
    }
    log(
      "session.start: session=\(session.id) identity=\(newIdentityLabel) "
        + "trigger=\(trigger.rawValue) sources=\(sourceLabel(session)) "
        + "superseded=\(toSupersede.count)")
    await startCapture(session.id, session.sources)
    if trigger == .browserExtension {
      scheduleBrowserAudioCheck(sessionID: session.id)
    }
    return session
  }

  /// `session.end`: closes the open interval, persists the final state, and
  /// fires the ended hook with the final session. Idempotent: ending an
  /// already-ended (still-known) session returns its final state.
  @discardableResult
  public func end(id: String, reason: EndReason = .client) async throws -> Session {
    guard var session = knownSession(id) else {
      throw SessionRegistryError.notFound(id)
    }
    if session.state == .ended {
      return session
    }
    let now = clock.now()
    if closeOpenInterval(of: &session, at: now) {
      appendEvent(session.id, event: "interval_closed", at: now)
    }
    session.state = .ended
    session.ended = now

    reconcileRoster(&session)
    logRosterSummary(session)
    try persist(session)
    appendEvent(session.id, event: "ended", at: now, reason: reason.rawValue)
    await publish(&session)
    sessions[session.id] = session
    if let identity = session.identity, byIdentity[identity] == session.id {
      byIdentity[identity] = nil
    }
    graceGeneration[session.id] = nil
    browserAudioWarned.remove(session.id)
    browserAudioCheckPending.remove(session.id)

    // Stop and tear down capture before the ended hook runs, so each source's
    // in-progress chunk is flushed and indexed to disk before transcription
    // reads it. Browser sources are already stopped by their ingest close; the
    // controller no-ops on those and stops the session's local sources.
    await stopCapture(session.id, session.sources)

    if let onEnded {
      await onEnded(session)
    }
    return session
  }

  /// Records that this session's transcript completed **successfully** at
  /// `at` — the durable marker the retention sweeper keys off. Idempotent; a
  /// later successful re-transcription moves the marker forward. A no-op for an
  /// unknown session (nothing to mark).
  public func markTranscriptCompleted(id: String, at: Instant) {
    guard var session = knownSession(id) else { return }
    session.transcriptCompleted = at
    do {
      try persist(session)
    } catch {
      log("session \(id): persisting transcript-completed marker failed: \(error)")
    }
    sessions[session.id] = session
  }

  /// Replaces this session's pipeline issues with what the latest on-end
  /// chain reported. A no-op for an unknown session.
  public func recordPipelineIssues(id: String, issues: [PipelineIssue]) {
    guard var session = knownSession(id), session.pipelineIssues != issues else { return }
    session.pipelineIssues = issues
    do {
      try persist(session)
    } catch {
      log("session \(id): persisting pipeline issues failed: \(error)")
    }
    sessions[session.id] = session
  }

  /// Replaces the notes this session's latest successful summarize wrote.
  /// A no-op for an unknown session.
  public func recordPublishedNotes(id: String, notes: [String]) {
    guard var session = knownSession(id), session.publishedNotes != notes else { return }
    session.publishedNotes = notes
    do {
      try persist(session)
    } catch {
      log("session \(id): persisting published notes failed: \(error)")
    }
    sessions[session.id] = session
  }

  /// `session.pause`: closes the open interval. No-op success if already
  /// paused; `session_ended` if the session is over.
  public func pause(id: String) async throws -> Session {
    var session = try liveSession(id)
    guard session.state == .active else {
      return session  // already paused — converge, don't error
    }
    let now = clock.now()
    if closeOpenInterval(of: &session, at: now) {
      appendEvent(session.id, event: "interval_closed", at: now)
    }
    session.state = .paused
    try persist(session)
    await publish(&session)
    sessions[session.id] = session
    return session
  }

  /// `session.resume`: opens a new interval. No-op success if already
  /// active; `session_ended` if the session is over.
  public func resume(id: String) async throws -> Session {
    var session = try liveSession(id)
    guard session.state == .paused else {
      return session  // already active — converge, don't error
    }
    let now = clock.now()
    session.intervals.append(SessionInterval(start: now))
    session.state = .active
    appendEvent(session.id, event: "interval_opened", at: now)
    try persist(session)
    await publish(&session)
    sessions[session.id] = session
    return session
  }

  /// `session.rename`. `ifRev` makes it a compare-and-set: a mismatch
  /// throws `conflict` instead of silently last-write-winning.
  public func rename(id: String, title: String, ifRev: Int?) async throws -> Session {
    guard var session = knownSession(id) else {
      throw SessionRegistryError.notFound(id)
    }
    if let ifRev, ifRev != session.rev {
      throw SessionRegistryError.conflict(
        "session '\(id)' is at rev \(session.rev), not \(ifRev)")
    }
    session.title = title
    try persist(session)
    appendEvent(session.id, event: "renamed", at: clock.now(), title: title)
    await publish(&session)
    sessions[session.id] = session
    return session
  }

  /// `session.attendee`: upsert by attendee `id`. Omitted fields keep the
  /// existing entry's values; a `source` link also joins the session's
  /// source list.
  public func upsertAttendee(_ params: SessionAttendeeParams) async throws -> Session {
    var session = try liveSession(params.session)
    let now = clock.now()

    var attendee =
      session.attendees.first(where: { $0.id == params.id })
      ?? SessionAttendee(id: params.id, joined: params.joined ?? now)
    let isNew = !session.attendees.contains(where: { $0.id == params.id })
    let hadLeft = attendee.left != nil

    if let displayName = params.displayName { attendee.displayName = displayName }
    if let joined = params.joined { attendee.joined = joined }
    if let left = params.left { attendee.left = left }
    if let source = params.source { attendee.source = source }
    // Omitted = "sender doesn't know": a later upsert without the field must
    // not erase the provenance the join declared.
    if let origin = params.origin { attendee.origin = origin }
    // Latched, never cleared: the client reports `self` on whichever upsert
    // happens to carry it, and a later upsert for the same attendee that
    // simply omits the field must not un-flag them.
    if let isLocal = params.isLocal, isLocal { attendee.isLocal = true }

    if let index = session.attendees.firstIndex(where: { $0.id == params.id }) {
      session.attendees[index] = attendee
    } else {
      session.attendees.append(attendee)
    }
    if let source = attendee.source {
      _ = mergeSources([source], into: &session)
    }

    // Trace every upsert so an empty `display_name`/`source` in session.toml is
    // attributable to "never sent" (recv_* is `-` on every upsert for this id)
    // vs "sent but not merged" (recv_* carried a value the stored field didn't
    // pick up) — issue #23's debug-logging requirement.
    log(
      "session.attendee upsert: session=\(session.id) attendee=\(params.id) new=\(isNew) "
        + "recv_display_name=\(logField(params.displayName)) "
        + "recv_source=\(logField(params.source?.rawValue)) "
        + "stored_display_name=\(logField(attendee.displayName)) "
        + "stored_source=\(logField(attendee.source?.rawValue))")

    try persist(session)
    if isNew {
      appendEvent(
        session.id, event: "attendee_joined", at: attendee.joined ?? now,
        attendee: attendee.id)
    }
    if !hadLeft, let left = attendee.left {
      appendEvent(session.id, event: "attendee_left", at: left, attendee: attendee.id)
    }
    await publish(&session)
    sessions[session.id] = session
    // A roster event is the watchdog's re-arm signal: a guest who joins (or
    // gets named) mid-session starts a fresh browser-audio clock.
    if session.trigger == .browserExtension && session.state != .ended {
      scheduleBrowserAudioCheck(sessionID: session.id)
    }
    return session
  }

  /// `session.list`: live + recently-ended sessions, sorted by start.
  /// Closed history is read from disk, not the socket.
  public func list() -> [Session] {
    sessions.values.sorted { $0.started < $1.started }
  }

  /// The live session id declared under `identity`, or `nil` when no live
  /// session has it — how `EarsDaemon.openIngestSource` resolves an ingest
  /// stream's membership tag to the session directory its audio lands in.
  public func sessionID(for identity: SessionIdentity) -> String? {
    byIdentity[identity]
  }

  /// `session.get`: a live/recent session, or (falling back) one read from
  /// disk.
  public func get(id: String) throws -> Session {
    guard let session = knownSession(id) else {
      throw SessionRegistryError.notFound(id)
    }
    return session
  }

  // MARK: - Ingest stream tracking (orphan grace)

  /// A live ingest stream opened for `source` — cancels any pending grace
  /// expiry for sessions that include it.
  ///
  /// A non-nil `session` is the client's membership tag: the daemon joins the
  /// source into that identity's live session itself (stashing the link until
  /// `session.start` arrives, if the open raced ahead of it). This is what
  /// keeps the ingest-idle grace policy sound when the client's own
  /// `session.attendee` source upserts never arrive — an MV3 service worker
  /// respawned mid-call has no session state to upsert from, but the tab's
  /// PCM keeps flowing with the tag attached.
  public func ingestStreamOpened(source: SourceID, session identity: SessionIdentity? = nil) async {
    liveIngest[source, default: 0] += 1
    if let identity {
      await link(source: source, to: identity)
    }

    // Scope the grace cancellation to the session this open's identity tag
    // resolves to — NOT every non-ended session whose roster happens to include
    // the (slot-style, non-unique) `source` label. Bumping the generation for
    // unrelated sessions sharing a `browser:meet:speaker-N` slot is exactly what
    // kept stale sessions perpetually alive (#24). With no tag, fall back to the
    // sessions that name the source (at most one under the single-active
    // invariant).
    let resolvedIdentity = identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
    let resolvedSessions: [String]
    if let identity, let id = byIdentity[identity] {
      resolvedSessions = [id]
    } else {
      resolvedSessions = sessions.values
        .filter { $0.state != .ended && $0.sources.contains(source) }
        .map(\.id)
    }
    for id in resolvedSessions {
      // Bump the generation: any in-flight grace timer becomes a no-op.
      graceGeneration[id, default: 0] += 1
      log(
        "grace cancelled: session=\(id) cause=ingest.open source=\(source.rawValue) "
          + "resolved_identity=\(resolvedIdentity) generation=\(graceGeneration[id]!)")
    }
  }

  /// A live ingest stream closed for `source` — when this leaves a browser
  /// session with no live streams at all, its grace clock starts.
  ///
  /// A non-nil `session` is the same membership tag the stream's
  /// `ingest.open` carried, echoed here so the close is scoped exactly the
  /// way the open is (#24): the grace clock starts only for the session that
  /// identity resolves to — NOT every non-ended session whose roster happens
  /// to include the (slot-style, non-unique) `source` label, which would let
  /// an unrelated call's dying stream start (or re-arm) another session's
  /// grace. With no tag, fall back to the sessions that name the source (at
  /// most one under the single-active invariant).
  public func ingestStreamClosed(source: SourceID, session identity: SessionIdentity? = nil) {
    let remaining = max(0, (liveIngest[source] ?? 0) - 1)
    liveIngest[source] = remaining == 0 ? nil : remaining
    if remaining == 0 {
      // A tag whose stream died before its session.start ever arrived links
      // nothing — a later session must not adopt a source that isn't flowing.
      pendingIngestLinks[source] = nil
    }
    let affected: [Session]
    if let identity {
      affected = byIdentity[identity].flatMap { sessions[$0] }.map { [$0] } ?? []
    } else {
      affected = sessions.values.filter { $0.state != .ended && $0.sources.contains(source) }
    }
    for session in affected
    where session.state != .ended && session.isBrowserSession && !hasLiveIngest(session) {
      scheduleGraceExpiry(sessionID: session.id)
    }
  }

  private func hasLiveIngest(_ session: Session) -> Bool {
    session.sources.contains { (liveIngest[$0] ?? 0) > 0 }
  }

  /// Daemon-side membership: joins `source` into the live session declared
  /// under `identity`, or stashes the link for `start` to claim when the
  /// `ingest.open` raced ahead of the `session.start`.
  private func link(source: SourceID, to identity: SessionIdentity) async {
    guard let id = byIdentity[identity], var session = sessions[id], session.state != .ended
    else {
      pendingIngestLinks[source] = identity
      return
    }
    guard mergeSources([source], into: &session) else { return }
    do {
      try persist(session)
    } catch {
      log(
        "session \(session.id): persisting ingest-linked source \(source.rawValue) failed: \(error)"
      )
    }
    await publish(&session)
    sessions[session.id] = session
  }

  /// Claims (and clears) every pending ingest link stashed for `identity`,
  /// sorted for deterministic source order.
  private func claimPendingLinks(for identity: SessionIdentity) -> [SourceID] {
    let claimed = pendingIngestLinks.filter { $0.value == identity }.keys
      .sorted { $0.rawValue < $1.rawValue }
    for source in claimed { pendingIngestLinks[source] = nil }
    return claimed
  }

  // MARK: - Browser-audio watchdog

  /// Arm one browser-audio check `browserAudioWarnSeconds` from now, unless
  /// one is already pending. Armed at `session.start` and re-armed by every
  /// attendee upsert (a guest who joins mid-session restarts the clock), so
  /// there is no self-rescheduling loop — each check either warns, or waits
  /// for the next roster event to arm the next one.
  ///
  /// The 2026-07-24 Brivo call (browser/dev/captures/
  /// 2026-07-24-meet-collections-drift.md) ran 21 minutes with the extension's
  /// control channel healthy — session started, both names on the roster —
  /// while not one byte of remote audio arrived: Meet had migrated call audio
  /// off the RTP path the extension taps, silently. The daemon-visible shape
  /// of that failure is precise: a browser-triggered session whose roster
  /// proves a multi-party call (≥ 2 named attendees) but whose sources never
  /// gain a single `browser:*` entry. This watchdog makes that shape loud.
  private func scheduleBrowserAudioCheck(sessionID: String) {
    guard browserAudioWarnSeconds > 0,
      !browserAudioWarned.contains(sessionID),
      !browserAudioCheckPending.contains(sessionID)
    else { return }
    browserAudioCheckPending.insert(sessionID)
    let wait = sleep
    let seconds = browserAudioWarnSeconds
    Task { [weak self] in
      await wait(seconds)
      await self?.checkBrowserAudio(sessionID: sessionID)
    }
  }

  private func checkBrowserAudio(sessionID: String) {
    browserAudioCheckPending.remove(sessionID)
    guard let session = sessions[sessionID],
      session.state != .ended,
      session.trigger == .browserExtension,
      !browserAudioWarned.contains(sessionID)
    else { return }
    if session.sources.contains(where: { $0.sourceClass == .browser }) {
      // The extension delivered at least one per-participant stream; a stream
      // that later goes dead is CaptureActor's dry-spell watchdog's job.
      return
    }
    let namedAttendees = session.attendees.filter { !($0.displayName ?? "").isEmpty }.count
    // Fewer than 2 names doesn't prove a multi-party call (guest may still be
    // in the lobby) — stay quiet; the upsert that names them re-arms the check.
    guard namedAttendees >= 2 else { return }
    browserAudioWarned.insert(sessionID)
    log(
      "⚠ session.browser_audio_missing: session=\(sessionID) "
        + "named_attendees=\(namedAttendees) age=\(ageSeconds(session))s — "
        + "roster shows a multi-party call but no browser:* audio source ever opened; "
        + "remote participants are NOT being recorded "
        + "(extension audio path down — see "
        + "browser/dev/captures/2026-07-24-meet-collections-drift.md)")
  }

  private func scheduleGraceExpiry(sessionID: String) {
    graceGeneration[sessionID, default: 0] += 1
    let generation = graceGeneration[sessionID]!
    let deadline = clock.now().advanced(by: graceSeconds)
    log(
      "grace scheduled: session=\(sessionID) "
        + "deadline=\(ISO8601InstantCodec.format(deadline)) generation=\(generation)")
    let wait = sleep
    let seconds = graceSeconds
    Task { [weak self] in
      await wait(seconds)
      await self?.expireIfStillOrphaned(sessionID: sessionID, generation: generation)
    }
  }

  private func expireIfStillOrphaned(sessionID: String, generation: Int) async {
    guard graceGeneration[sessionID] == generation,
      let session = sessions[sessionID],
      session.state != .ended,
      session.isBrowserSession,
      !hasLiveIngest(session)
    else {
      log(
        "grace expiry no-op: session=\(sessionID) generation=\(generation) "
          + "current_generation=\(graceGeneration[sessionID].map(String.init) ?? "-")")
      return
    }
    log("grace expiry firing: session=\(sessionID) generation=\(generation) reason=ingest-idle")
    do {
      _ = try await end(id: sessionID, reason: .ingestIdle)
      log("session \(sessionID) ended: ingest idle past grace")
    } catch {
      log("session \(sessionID) orphan expiry failed: \(error)")
    }
  }

  // MARK: - Internals

  private func knownSession(_ id: String) -> Session? {
    if let session = sessions[id] { return session }
    return try? SessionStore.read(sessionID: id, dataRoot: dataRoot)
  }

  /// A session a lifecycle verb may still mutate.
  private func liveSession(_ id: String) throws -> Session {
    guard let session = knownSession(id) else {
      throw SessionRegistryError.notFound(id)
    }
    guard session.state != .ended else {
      throw SessionRegistryError.ended(id)
    }
    return session
  }

  /// Closes the open interval, if any. Returns whether one was closed.
  private func closeOpenInterval(of session: inout Session, at now: Instant) -> Bool {
    guard let index = session.intervals.lastIndex(where: { $0.end == nil }) else {
      return false
    }
    session.intervals[index].end = now
    return true
  }

  /// A new session's starting source list: the client-declared sources, plus
  /// (for browser-triggered sessions only) the configured ``localBrowserSources``
  /// that the daemon is actually capturing right now — the host's own mic
  /// joins the session so `transcribe --session` covers both sides. Non-browser
  /// (manual/CLI) sessions are left exactly as declared; a CLI caller names
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

  private func mergeSources(_ sources: [SourceID], into session: inout Session) -> Bool {
    var changed = false
    for source in sources where !session.sources.contains(source) {
      session.sources.append(source)
      changed = true
    }
    return changed
  }

  private func persist(_ session: Session) throws {
    try SessionStore.write(session, dataRoot: dataRoot)
  }

  /// Binding hints recovered from the session's attribution flight-recorder
  /// log (`attribution.jsonl`), for reconciliation. Best-effort by contract:
  /// a session with no log — or an unreadable one — reconciles from the
  /// roster alone, exactly as before hints existed; nothing here may block
  /// `session.end`.
  private func attributionEvidence(
    sessionID: String
  ) -> (hints: [AttributionBindingHint], speech: AttributionSpeechEvidence?) {
    let url = SessionAttributionLog.fileURL(dataRoot: dataRoot, sessionID: sessionID)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], nil) }
    return (
      AttributionBindingHints.parse(jsonl: text),
      AttributionBindingHints.speechEvidence(jsonl: text)
    )
  }

  /// Publishes the session as a revision-tagged state event, stamping the
  /// assigned revision into the object itself (result and notification carry
  /// the same `rev`).
  private func publish(_ session: inout Session) async {
    guard let bus else { return }
    let snapshot = session
    let rev = await bus.publishState { rev in
      var stamped = snapshot
      stamped.rev = rev
      return .session(stamped)
    }
    session.rev = rev
  }

  /// Best-effort `events.jsonl` append — never load-bearing.
  private func appendEvent(
    _ sessionID: String, event: String, at instant: Instant,
    attendee: String? = nil, title: String? = nil, reason: String? = nil
  ) {
    let entry = SessionEventLog.Entry(
      t: ISO8601InstantCodec.format(instant), event: event, attendee: attendee,
      title: title, reason: reason)
    do {
      try SessionEventLog.append(entry, dataRoot: dataRoot, sessionID: sessionID)
    } catch {
      log("session \(sessionID): events.jsonl append failed: \(error)")
    }
  }

  /// Renders an optional string for a log line: the quoted value, or `-` for
  /// nil/empty — so "field absent" and "field present" read distinctly.
  private func logField(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "-" }
    return "\"\(value)\""
  }

  /// Derives the session's speaker map, warnings, and — when nothing ever
  /// named it — its title, from the final roster.
  ///
  /// Runs at `session.end`, on the last state before anything downstream
  /// reads it: `transcribe` labels turns from ``Session/speakers``, and every
  /// published path interpolates ``Session/title``. Doing it here rather than
  /// live means it sees the *whole* call — an attendee who joins late, a
  /// binding made and then contradicted — instead of deciding on partial
  /// evidence and never revisiting it.
  ///
  /// **Title precedence.** A title anyone else established wins outright, and
  /// the roster is consulted only for a session still carrying the platform's
  /// own default. That default is regenerated and compared rather than
  /// tracked with a flag, so the order needs no extra state: the extension's
  /// meeting-name scrape (`MeetMeetingTitleWatcher` → `session.rename`) and a
  /// manual rename both take precedence simply by having changed the title
  /// away from it. The roster is the last resort before an opaque meeting id.
  private func reconcileRoster(_ session: inout Session) {
    let evidence = attributionEvidence(sessionID: session.id)
    let outcome = RosterReconciler.reconcile(
      attendees: session.attendees, sources: session.sources, sessionStart: session.started,
      hints: evidence.hints, speech: evidence.speech)
    session.speakers = outcome.speakers
    session.warnings = outcome.warnings
    // Stamp which derivation produced this map, so `transcribe` can tell a
    // current map from one a since-fixed reconciler left behind and re-derive
    // the stale one.
    session.reconcilerVersion = RosterReconciler.version
    // The reconciler's local-participant conclusion is written back onto the
    // roster — in both directions. Setting the concluded row records the
    // answer, so `session.toml` carries the conclusion and not just the
    // evidence for it; clearing every other row is what makes the upsert
    // latch above (set-once, so a client omitting `self` can't un-flag
    // anyone) revisable after all: the registry never un-flags on a client's
    // say-so, but a reconciliation that showed the flag impossible does, and
    // its evidence is persisted in `warnings` (``RosterReconciler/LocalResolution/revised``).
    if let localID = outcome.localAttendeeID {
      for index in session.attendees.indices {
        session.attendees[index].isLocal = session.attendees[index].id == localID
      }
    }

    let speakerMap = outcome.speakers
      .map { "\($0.source.rawValue)→\"\($0.name)\"(\($0.confidence.rawValue))" }
      .joined(separator: ",")
    log(
      "session.end reconciled: session=\(session.id) "
        + "local=\(logField(outcome.localAttendeeID))(\(outcome.localResolution.rawValue)) "
        + "speakers=\(speakerMap.isEmpty ? "-" : speakerMap) "
        + "warnings=\(outcome.warnings.count)")
    for warning in outcome.warnings {
      log("session.end warning: session=\(session.id) \(warning)")
    }

    guard session.hasDefaultTitle else { return }
    guard
      let derived = RosterReconciler.derivedTitle(
        attendees: session.attendees, localAttendeeID: outcome.localAttendeeID)
    else { return }
    log(
      "session.end titled from roster: session=\(session.id) "
        + "title=\"\(derived)\" (was the platform default \"\(session.title)\")")
    session.title = derived
    appendEvent(session.id, event: "renamed", at: session.ended ?? session.started, title: derived)
  }

  /// At session end, log which attendees resolved a name and a source and which
  /// are still unresolved (name and/or source missing). This makes an
  /// unresolved attendee an explicit, greppable fact rather than a silent empty
  /// string in session.toml (issue #23's acceptance criterion + roster-summary
  /// logging requirement).
  private func logRosterSummary(_ session: Session) {
    let withName = session.attendees.filter { !($0.displayName ?? "").isEmpty }.count
    let withSource = session.attendees.filter { $0.source != nil }.count
    let unresolved = session.attendees
      .filter { ($0.displayName ?? "").isEmpty || $0.source == nil }
      .map { attendee in
        let hasName = !(attendee.displayName ?? "").isEmpty
        let hasSource = attendee.source != nil
        return "\(attendee.id)(name=\(hasName ? "yes" : "no"),source=\(hasSource ? "yes" : "no"))"
      }
    log(
      "session.end roster summary: session=\(session.id) attendees=\(session.attendees.count) "
        + "with_name=\(withName) with_source=\(withSource) "
        + "unresolved=\(unresolved.isEmpty ? "-" : unresolved.joined(separator: ","))")
  }

  // MARK: - Log helpers

  /// `platform:external_id`, or `-` for a manual session — a stable, greppable
  /// identity token for the supersede/boot logs.
  private func identityLabel(_ session: Session) -> String {
    session.identity.map { "\($0.platform):\($0.externalID)" } ?? "-"
  }

  /// A comma-joined source list, or `-` when empty.
  private func sourceLabel(_ session: Session) -> String {
    session.sources.isEmpty ? "-" : session.sources.map(\.rawValue).joined(separator: ",")
  }

  /// Whole seconds since this session started, at the current clock — how a
  /// weeks-old "active" session reads as anomalous in the boot/supersede logs.
  private func ageSeconds(_ session: Session) -> Int {
    Int(clock.now().interval(since: session.started))
  }

  /// The most recent interval boundary (or `started` if none) — the session's
  /// last observable activity, surfaced alongside age in the supersede/boot logs.
  private func lastActivity(_ session: Session) -> Instant {
    var latest = session.started
    for interval in session.intervals {
      latest = max(latest, interval.start)
      if let end = interval.end {
        latest = max(latest, end)
      }
    }
    return latest
  }
}
