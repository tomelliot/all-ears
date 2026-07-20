import EarsCore
import EarsDataStore
import EarsIPC
import Foundation

/// Dispatches v2 control calls to the right actor and builds each reply —
/// the seam both `EarsIPC` control transports plug into. It owns the source
/// id → ``CaptureActor`` lookup, the ``SessionRegistry`` and
/// ``MeetingRegistry`` references, and the daemon start instant (for
/// `uptime_s`). Deliberately **thin wiring**: it decodes intent and shapes
/// wire payloads, pushing all real logic into the registries and capture
/// actors. An `actor` because its source→actor map is mutable at runtime
/// (`sources.remove`, dynamic ingest sources).
///
/// The transports own the envelope, `hello`, and capability enforcement
/// (privilege differs by transport, not by dialect) — every ``ControlCall``
/// arriving here has already cleared both, so dispatch is identical on the
/// Unix socket and the loopback WebSocket.
///
/// ## Routing
///
/// | call | routed to | result payload |
/// |---|---|---|
/// | `status` | every ``CaptureActor/status()`` + registries | `StatusData` |
/// | `subscribe` | registries + ``EventBus/currentRev()`` | `SnapshotData` (the transport registered the filter first) |
/// | `meeting.*` | ``MeetingRegistry`` | the full meeting object (`meeting.list` → `MeetingListData`) |
/// | `session.*`, `mark` | ``SessionRegistry`` | as v1 |
/// | `segment.publish`, `job.publish` | the ``EventBus`` (notification-only) | `EmptyData` |
/// | `sources.*`, `capture.*`, `flush` | ``CaptureActor``s | as v1 |
///
/// `sources.add` remains unimplemented in this build (runtime
/// `CaptureActor` construction is a documented Phase-4 seam) and fails
/// clearly rather than leaving a half-built source.
public actor ControlServer {
  private var captureActors: [SourceID: CaptureActor]
  private let sessions: SessionRegistry
  /// The meeting lifecycle owner; `nil` (for callers that don't wire
  /// meetings) makes every `meeting.*` call fail clearly.
  private let meetings: MeetingRegistry?
  /// Called after every successful `session.close`, with the closed
  /// descriptor — the seam ``EarsDaemon`` hangs the browser-triggered
  /// on-close transcribe pipeline off. `nil` does nothing.
  private let onSessionClosed: (@Sendable (SessionDescriptor) async -> Void)?
  private let dataRoot: URL
  private let clock: any NowProviding
  /// The daemon's start instant, for the `status` reply's `uptime_s`.
  private let startInstant: Instant
  /// The live-feed bus: `segment.publish`/`job.publish` forward through it,
  /// and `subscribe` snapshots read its revision. `nil` drops publishes and
  /// snapshots at rev 0.
  private let bus: EventBus?

  public init(
    captureActors: [SourceID: CaptureActor],
    sessions: SessionRegistry,
    dataRoot: URL,
    startInstant: Instant,
    clock: any NowProviding = SystemClock(),
    bus: EventBus? = nil,
    meetings: MeetingRegistry? = nil,
    onSessionClosed: (@Sendable (SessionDescriptor) async -> Void)? = nil
  ) {
    self.captureActors = captureActors
    self.sessions = sessions
    self.meetings = meetings
    self.onSessionClosed = onSessionClosed
    self.dataRoot = dataRoot
    self.startInstant = startInstant
    self.clock = clock
    self.bus = bus
  }

  /// The `@Sendable` closure to hand both transports as their handler.
  public nonisolated func makeHandler() -> ControlHandler {
    { call in await self.handle(call) }
  }

  /// Registers a `CaptureActor` built after construction — ``EarsDaemon``
  /// calls this for a dynamically-created `browser:<label>` source (its
  /// first `ingest.open`) so `status`/`sources.list` see it without a
  /// restart.
  public func registerDynamicSource(_ actor: CaptureActor, id: SourceID) {
    captureActors[id] = actor
  }

  /// Dispatch one call and build its reply. Never throws: domain errors are
  /// rendered as stable-coded ``WireError``s.
  public func handle(_ call: ControlCall) async -> ControlReply {
    switch call {
    case .status:
      return await handleStatus()
    case .subscribe:
      return await handleSubscribe()

    case .meetingStart(let params):
      return await withMeetings { try await $0.start(params) }
    case .meetingEnd(let meeting):
      return await withMeetings { try await $0.end(id: meeting) }
    case .meetingPause(let meeting):
      return await withMeetings { try await $0.pause(id: meeting) }
    case .meetingResume(let meeting):
      return await withMeetings { try await $0.resume(id: meeting) }
    case .meetingRename(let params):
      return await withMeetings {
        try await $0.rename(id: params.meeting, title: params.title, ifRev: params.ifRev)
      }
    case .meetingAttendee(let params):
      return await withMeetings { try await $0.upsertAttendee(params) }
    case .meetingGet(let meeting):
      return await withMeetings { try await $0.get(id: meeting) }
    case .meetingList:
      guard let meetings else {
        return .failure(.internalError, "this daemon has no meeting registry")
      }
      return ControlReply(result: MeetingListData(meetings: await meetings.list()))

    case .sessionOpen(let params):
      return await handleSessionOpen(params)
    case .sessionClose(let id):
      return await handleSessionClose(id: id)
    case .sessionList:
      let summaries = await sessions.list().map(SessionSummary.init)
      return ControlReply(result: SessionListData(sessions: summaries))
    case .sessionAddSource(let id, let source):
      do {
        _ = try await sessions.addSource(id: id, source: source)
        return ControlReply(result: EmptyData())
      } catch {
        return ControlReply(error: wireError(for: error))
      }
    case .mark(let sources, let slug, let range):
      do {
        let descriptor = try await sessions.mark(sources: sources, slug: slug, range: range)
        return ControlReply(result: SessionOpenData(id: descriptor.id))
      } catch {
        return ControlReply(error: wireError(for: error))
      }

    case .segmentPublish(let params):
      // A pass-through to the live feed, not a new source of truth: no
      // validation beyond the wire shape, no persistence — the durable
      // transcript is the on-disk file the publishing process writes itself.
      await bus?.publish(.segment(params))
      return ControlReply(result: EmptyData())
    case .jobPublish(let params):
      // Same notification-only pattern: pipeline tools report progress, the
      // daemon persists nothing, subscribers get real state.
      await bus?.publish(.job(params))
      return ControlReply(result: EmptyData())

    case .sourcesList:
      return ControlReply(result: SourcesListData(sources: await sourceStatuses()))
    case .sourcesAdd:
      return .failure(
        .invalidRequest,
        "sources.add is not supported in this build (Phase 4 scope: runtime CaptureActor construction)"
      )
    case .sourcesRemove(let source):
      return await handleSourcesRemove(source)
    case .sourcesEnable(let source):
      return await withSource(source) { try await $0.start() }
    case .sourcesDisable(let source):
      return await withSource(source) { await $0.stop() }
    case .capturePause(let source):
      guard let source else { return await fanOut { try await $0.pause() } }
      return await withSource(source) { try await $0.pause() }
    case .captureResume(let source):
      guard let source else { return await fanOut { try await $0.resume() } }
      return await withSource(source) { try await $0.resume() }
    case .flush:
      return await fanOut { try await $0.flush() }
    }
  }

  // MARK: - status / subscribe

  private func handleStatus() async -> ControlReply {
    let uptime = max(0, Int(clock.now().interval(since: startInstant)))
    let liveMeetings = (await meetings?.list() ?? []).filter { $0.state != .ended }
    let openSessions = await sessions.list().filter { $0.state == .open }
    return ControlReply(
      result: StatusData(
        uptimeSeconds: uptime,
        sources: await sourceStatuses(),
        meetings: liveMeetings,
        sessions: openSessions.map(SessionSummary.init)))
  }

  /// Builds the `subscribe` snapshot. The revision is read *before* the
  /// state lists so a racing mutation shows up as snapshot content plus a
  /// rev-above-snapshot event (a harmless re-apply), never as a silently
  /// missed update.
  private func handleSubscribe() async -> ControlReply {
    let rev = await bus?.currentRev() ?? 0
    let liveMeetings = (await meetings?.list() ?? []).filter { $0.state != .ended }
    let openSessions = await sessions.list().filter { $0.state == .open }
    return ControlReply(
      result: SnapshotData(
        rev: rev,
        meetings: liveMeetings,
        sources: await sourceStatuses(),
        sessions: openSessions.map(SessionSummary.init)))
  }

  /// Every source's wire status, in a deterministic (id-sorted) order.
  private func sourceStatuses() async -> [SourceStatus] {
    var statuses: [SourceStatus] = []
    for (_, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      statuses.append(SourceStatus(await actor.status()))
    }
    return statuses
  }

  // MARK: - meetings

  private func withMeetings(
    _ operation: (MeetingRegistry) async throws -> Meeting
  ) async -> ControlReply {
    guard let meetings else {
      return .failure(.internalError, "this daemon has no meeting registry")
    }
    do {
      return ControlReply(result: try await operation(meetings))
    } catch {
      return ControlReply(error: wireError(for: error))
    }
  }

  // MARK: - sessions

  private func handleSessionOpen(_ params: SessionOpenParams) async -> ControlReply {
    do {
      let descriptor = try await sessions.open(
        sources: params.sources, slug: params.slug, start: params.start, vocab: params.vocab,
        trigger: params.trigger ?? .manual)
      return ControlReply(result: SessionOpenData(id: descriptor.id))
    } catch {
      return ControlReply(error: wireError(for: error))
    }
  }

  private func handleSessionClose(id: String) async -> ControlReply {
    do {
      let descriptor = try await sessions.close(id: id)
      await onSessionClosed?(descriptor)
      return ControlReply(result: EmptyData())
    } catch {
      return ControlReply(error: wireError(for: error))
    }
  }

  // MARK: - sources / capture

  private func handleSourcesRemove(_ source: SourceID) async -> ControlReply {
    guard let actor = captureActors[source] else {
      return ControlReply(error: unknownSource(source))
    }
    await actor.stop()
    captureActors[source] = nil
    // Ephemeral per `ActorContracts`: only this source's own `meta.toml` is
    // removed, never `config.toml`. Best-effort — a missing file is fine.
    try? FileManager.default.removeItem(
      at: DataStoreLayout.metaTomlFile(dataRoot: dataRoot, sourceID: source))
    return ControlReply(result: EmptyData())
  }

  private func withSource(
    _ source: SourceID, _ operation: (CaptureActor) async throws -> Void
  ) async -> ControlReply {
    guard let actor = captureActors[source] else {
      return ControlReply(error: unknownSource(source))
    }
    do {
      try await operation(actor)
      return ControlReply(result: EmptyData())
    } catch {
      return ControlReply(error: wireError(for: error))
    }
  }

  /// Runs `operation` against every source, in id-sorted order, collecting
  /// per-source failures rather than stopping at the first one. Succeeds
  /// only if every source succeeded; otherwise the failure names each
  /// failing source.
  private func fanOut(
    _ operation: (CaptureActor) async throws -> Void
  ) async -> ControlReply {
    var failures: [String] = []
    for (id, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      do {
        try await operation(actor)
      } catch {
        failures.append("\(id.rawValue): \(wireError(for: error).message)")
      }
    }
    guard failures.isEmpty else {
      return .failure(.internalError, failures.joined(separator: "; "))
    }
    return ControlReply(result: EmptyData())
  }

  // MARK: - Error mapping

  private func unknownSource(_ id: SourceID) -> WireError {
    WireError(code: .sourceNotFound, message: "unknown source '\(id.rawValue)'")
  }

  /// Maps thrown registry/actor errors to the wire's stable codes; anything
  /// unrecognized becomes `internal` with its description rather than being
  /// swallowed.
  private func wireError(for error: Error) -> WireError {
    if let error = error as? CaptureActorError {
      switch error {
      case .alreadyCapturing:
        return WireError(code: .invalidRequest, message: "source is already capturing")
      case .notPaused:
        return WireError(code: .invalidRequest, message: "source is not paused")
      }
    }
    if let error = error as? SessionRegistryError {
      switch error {
      case .unknownSource(let id):
        return WireError(code: .sourceNotFound, message: "unknown source '\(id.rawValue)'")
      case .noSources:
        return WireError(code: .invalidRequest, message: "at least one source is required")
      case .sessionNotFound(let id):
        return WireError(code: .sessionNotFound, message: "no such session '\(id)'")
      case .sessionAlreadyClosed(let id):
        return WireError(
          code: .sessionAlreadyClosed, message: "session '\(id)' is already closed")
      }
    }
    if let error = error as? MeetingRegistryError {
      switch error {
      case .notFound(let id):
        return WireError(code: .meetingNotFound, message: "no active meeting \(id)")
      case .ended(let id):
        return WireError(code: .meetingEnded, message: "meeting \(id) has ended")
      case .conflict(let message):
        return WireError(code: .conflict, message: message)
      }
    }
    return WireError(code: .internalError, message: "\(error)")
  }
}
