import EarsCore
import EarsDataStore
import EarsIPC
import Foundation

/// Dispatches v2 control calls to the right actor and builds each reply —
/// the seam both `EarsIPC` control transports plug into. It owns the source
/// id → ``CaptureActor`` lookup, the ``SessionRegistry`` reference, and the
/// daemon start instant (for `uptime_s`). Deliberately **thin wiring**: it
/// decodes intent and shapes wire payloads, pushing all real logic into the
/// registry and capture actors. An `actor` because its source→actor map is
/// mutable at runtime (`sources.remove`, dynamic ingest sources).
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
/// | `status` | every ``CaptureActor/status()`` + registry | `StatusData` |
/// | `subscribe` | registry + ``EventBus/currentRev()`` | `SnapshotData` (the transport registered the filter first) |
/// | `session.*` | ``SessionRegistry`` | the full session object (`session.list` → `SessionListData`) |
/// | `segment.publish`, `job.publish` | the ``EventBus`` (notification-only) | `EmptyData` |
/// | `sources.*`, `capture.*`, `flush` | ``CaptureActor``s | as v1 |
///
/// `sources.add` remains unimplemented in this build (runtime
/// `CaptureActor` construction is a documented Phase-4 seam) and fails
/// clearly rather than leaving a half-built source.
public actor ControlServer {
  private var captureActors: [SourceID: CaptureActor]
  /// The session lifecycle owner; `nil` (for callers that don't wire
  /// sessions) makes every `session.*` call fail clearly.
  private let sessions: SessionRegistry?
  private let dataRoot: URL
  private let clock: any NowProviding
  /// The daemon's start instant, for the `status` reply's `uptime_s`.
  private let startInstant: Instant
  /// The live-feed bus: `segment.publish`/`job.publish` forward through it,
  /// and `subscribe` snapshots read its revision. `nil` drops publishes and
  /// snapshots at rev 0.
  private let bus: EventBus?
  /// `session.retry`'s handler; `nil` fails the call clearly.
  private let retrySession: RetryHandler?

  /// Reruns an ended session's on-end chain and returns the session once it
  /// stops.
  public typealias RetryHandler = @Sendable (SessionRetryParams) async throws -> Session

  public init(
    captureActors: [SourceID: CaptureActor],
    dataRoot: URL,
    startInstant: Instant,
    clock: any NowProviding = SystemClock(),
    bus: EventBus? = nil,
    sessions: SessionRegistry? = nil,
    retrySession: RetryHandler? = nil
  ) {
    self.captureActors = captureActors
    self.sessions = sessions
    self.dataRoot = dataRoot
    self.startInstant = startInstant
    self.clock = clock
    self.bus = bus
    self.retrySession = retrySession
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

  /// Drops a source from the lookup — ``EarsDaemon`` calls this when a
  /// session-scoped source's `CaptureActor` is torn down at session end, so
  /// `status`/`sources.list` stop reporting a source that is no longer
  /// recording. Its `meta.toml` and audio stay on disk (retention's concern).
  public func unregisterDynamicSource(id: SourceID) {
    captureActors[id] = nil
  }

  /// Dispatch one call and build its reply. Never throws: domain errors are
  /// rendered as stable-coded ``WireError``s.
  public func handle(_ call: ControlCall) async -> ControlReply {
    switch call {
    case .status:
      return await handleStatus()
    case .subscribe:
      return await handleSubscribe()

    case .sessionStart(let params):
      return await withSessions { try await $0.start(params) }
    case .sessionEnd(let session):
      return await withSessions { try await $0.end(id: session) }
    case .sessionPause(let session):
      return await withSessions { try await $0.pause(id: session) }
    case .sessionResume(let session):
      return await withSessions { try await $0.resume(id: session) }
    case .sessionRename(let params):
      return await withSessions {
        try await $0.rename(id: params.session, title: params.title, ifRev: params.ifRev)
      }
    case .sessionAttendee(let params):
      return await withSessions { try await $0.upsertAttendee(params) }
    case .sessionGet(let session):
      return await withSessions { try await $0.get(id: session) }
    case .sessionRetry(let params):
      guard let retrySession else {
        return .failure(.internalError, "this daemon cannot retry sessions")
      }
      do {
        return ControlReply(result: try await retrySession(params))
      } catch {
        return ControlReply(error: wireError(for: error))
      }
    case .sessionList:
      guard let sessions else {
        return .failure(.internalError, "this daemon has no session registry")
      }
      return ControlReply(result: SessionListData(sessions: await sessions.list()))

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
    let liveSessions = (await sessions?.list() ?? []).filter { $0.state != .ended }
    return ControlReply(
      result: StatusData(
        uptimeSeconds: uptime,
        sources: await sourceStatuses(),
        sessions: liveSessions))
  }

  /// Builds the `subscribe` snapshot. The revision is read *before* the
  /// state lists so a racing mutation shows up as snapshot content plus a
  /// rev-above-snapshot event (a harmless re-apply), never as a silently
  /// missed update.
  private func handleSubscribe() async -> ControlReply {
    let rev = await bus?.currentRev() ?? 0
    let liveSessions = (await sessions?.list() ?? []).filter { $0.state != .ended }
    return ControlReply(
      result: SnapshotData(
        rev: rev,
        sessions: liveSessions,
        sources: await sourceStatuses()))
  }

  /// Every source's wire status, in a deterministic (id-sorted) order.
  private func sourceStatuses() async -> [SourceStatus] {
    var statuses: [SourceStatus] = []
    for (_, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      statuses.append(SourceStatus(await actor.status()))
    }
    return statuses
  }

  // MARK: - sessions

  private func withSessions(
    _ operation: (SessionRegistry) async throws -> Session
  ) async -> ControlReply {
    guard let sessions else {
      return .failure(.internalError, "this daemon has no session registry")
    }
    do {
      return ControlReply(result: try await operation(sessions))
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
      case .notFound(let id):
        return WireError(code: .sessionNotFound, message: "no active session \(id)")
      case .ended(let id):
        return WireError(code: .sessionEnded, message: "session \(id) has ended")
      case .conflict(let message):
        return WireError(code: .conflict, message: message)
      }
    }
    if let error = error as? SessionRetryError {
      if case .busy = error { return WireError(code: .conflict, message: error.description) }
      return WireError(code: .invalidRequest, message: error.description)
    }
    return WireError(code: .internalError, message: "\(error)")
  }
}

/// Why `session.retry` refused to run. `busy` maps to `conflict` on the
/// wire; the rest to `invalid_request`.
public enum SessionRetryError: Error, Sendable, Hashable, CustomStringConvertible {
  case noRegistry
  case notEnded(String)
  case chainDisabled
  case unknownStage(String)
  case stageNotConfigured(OnEndStage)
  case missingInput(OnEndStage)
  case busy(String)

  public var description: String {
    switch self {
    case .noRegistry:
      return "this daemon has no session registry"
    case .notEnded(let id):
      return "session \(id) has not ended; its pipeline runs when it does"
    case .chainDisabled:
      return "[earsd.sessions] on_end_stages is empty, so there is no chain to retry"
    case .unknownStage(let name):
      return
        "unknown stage '\(name)' (valid: "
        + "\(OnEndStage.allCases.map(\.rawValue).joined(separator: ", ")))"
    case .stageNotConfigured(let stage):
      return "\(stage.rawValue) is not in [earsd.sessions] on_end_stages"
    case .missingInput(let stage):
      return "retrying from \(stage.rawValue) needs the input file it reads"
    case .busy(let id):
      return "session \(id) already has a pipeline run in progress"
    }
  }
}
