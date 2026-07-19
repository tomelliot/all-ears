import EarsCore
import EarsDataStore
import EarsIPC
import Foundation

/// Dispatches control-socket commands to the right actor and builds each
/// reply — the seam `EarsIPC.ControlSocketServer` plugs into. It owns the
/// source id → ``CaptureActor`` lookup, a ``SessionRegistry`` reference, and
/// the daemon start instant (for `uptime_s`). Deliberately **thin wiring**: it
/// decodes intent and shapes wire payloads, pushing all real logic into
/// ``CaptureActor`` / ``SessionRegistry``. An `actor` because its source→actor
/// map is mutable at runtime (`sources.add`/`sources.remove`).
///
/// ## Transport seam
///
/// `ControlSocketServer`'s handler type is
/// `@Sendable (ControlRequest) async -> ControlReply`. ``makeHandler()``
/// produces exactly that closure over this actor; pass its result as the
/// server's `handler`. The reply is a type-erased `ControlReply` because a
/// single handler can't name every command's concrete `ControlResponse<Payload>`
/// (see `EarsIPC.ControlReply`).
///
/// ## Command routing (the sixteen `ControlRequest` cases)
///
/// | command | routed to | reply payload |
/// |---|---|---|
/// | `status` | every ``CaptureActor/status()`` + ``SessionRegistry`` | `StatusData` |
/// | `sources.list` | every ``CaptureActor/status()`` | `SourcesListData` |
/// | `sources.add` | — (not supported in this build) | failure: "not supported" |
/// | `sources.remove` | removes this source's `meta.toml` + map entry | `EmptyData` |
/// | `sources.enable` | ``CaptureActor/start()`` | `EmptyData` |
/// | `sources.disable` | ``CaptureActor/stop()`` | `EmptyData` |
/// | `capture.pause` | ``CaptureActor/pause()`` (one source, or all) | `EmptyData` |
/// | `capture.resume` | ``CaptureActor/resume()`` (one source, or all) | `EmptyData` |
/// | `session.open` | ``SessionRegistry/open(sources:slug:start:vocab:trigger:)`` | `SessionOpenData` |
/// | `session.close` | ``SessionRegistry/close(id:)`` | `EmptyData` |
/// | `session.list` | ``SessionRegistry/list()`` | `SessionListData` |
/// | `mark` | ``SessionRegistry/mark(sources:slug:range:trigger:)`` | `SessionOpenData` |
/// | `ingest.open` | — (WebSocket-only, see below) | failure: "use the WebSocket ingest endpoint" |
/// | `ingest.close` | — (WebSocket-only, see below) | failure: "use the WebSocket ingest endpoint" |
/// | `segment.publish` | the injected `eventSink` (``EventBus``, → live feed) | `EmptyData` |
/// | `flush` | ``CaptureActor/flush()`` on every enabled source | `EmptyData` |
///
/// ### Locked routing decisions (re-confirmed from the spec)
///
/// - **`sources.add`/`sources.remove` are ephemeral** — never rewriting the
///   suite's `config.toml` — but they're not symmetric in this build.
///   `sources.remove` only ever *shrinks* the in-memory `captureActors` map
///   (stop the actor, drop the entry, best-effort delete its `meta.toml`), so
///   it needs no new backend/actor and is fully implemented. `sources.add`
///   would need to construct a brand-new source's live `CaptureBackend` +
///   `CaptureActor` at runtime — a documented Phase-4 seam, out of scope for
///   Phase 1's mic-only daemon — so it always replies with a clear "not
///   supported in this build" failure instead. (Writing just an inert
///   `meta.toml` with no matching `CaptureActor` was considered and rejected:
///   the added source would then be invisible to `status`/`sources.list`,
///   which is worse than failing loudly.)
/// - **`ingest.open`/`ingest.close` reply with an explicit failure on this
///   socket** — browser ingest is WebSocket-only (`[earsd.ingest_ws]`, see
///   `EarsIPC.IngestWebSocketServer` and `specs/transport.md`); the Unix
///   control socket never accepts binary PCM, so it fails clearly here
///   rather than silently accepting a stream it can't consume.
/// - **`flush` finalizes and indexes** each enabled source's in-progress chunk
///   then opens a fresh one (``CaptureActor/flush()``), not a bare fsync of an
///   unindexed partial.
/// - **`capture.pause`/`capture.resume` with `source == nil`** fan out to every
///   ``CaptureActor``; with a concrete id they target just that one. An unknown
///   id (here or in `sources.enable`/`disable`) becomes an `ok:false` reply.
public actor ControlServer {
  private var captureActors: [SourceID: CaptureActor]
  private let sessions: SessionRegistry
  private let dataRoot: URL
  private let clock: any NowProviding
  /// The daemon's start instant, for the `status` reply's `uptime_s`.
  private let startInstant: Instant
  /// Where `segment.publish` forwards its event (``EarsDaemon`` supplies its
  /// ``EventBus``'s `publish`) — the same closure seam every other live-feed
  /// producer uses. `nil` publishes nothing; the command still replies
  /// `ok:true` either way, matching the live feed's drop-when-unattached
  /// semantics (the event is a notification, not persisted state).
  private let eventSink: EventSink?

  /// - Parameters:
  ///   - captureActors: The per-source actors, keyed by source id. Mutable —
  ///     `sources.add`/`sources.remove` change it at runtime.
  ///   - sessions: The session lifecycle owner.
  ///   - dataRoot: The suite's data root (for `sources.add`'s `meta.toml`).
  ///   - startInstant: When the daemon started, for `uptime_s`.
  ///   - clock: Wall-clock seam; injected so tests never touch real time.
  ///   - eventSink: Live-feed publish seam for `segment.publish` (see the
  ///     property doc); `nil` (the default) drops published segments.
  public init(
    captureActors: [SourceID: CaptureActor],
    sessions: SessionRegistry,
    dataRoot: URL,
    startInstant: Instant,
    clock: any NowProviding = SystemClock(),
    eventSink: EventSink? = nil
  ) {
    self.captureActors = captureActors
    self.sessions = sessions
    self.dataRoot = dataRoot
    self.startInstant = startInstant
    self.clock = clock
    self.eventSink = eventSink
  }

  /// The `@Sendable` closure to hand `ControlSocketServer` as its `handler`.
  /// Pure wiring: forwards each request to ``handle(_:)`` on this actor.
  public nonisolated func makeHandler() -> ControlSocketServer.Handler {
    { request in await self.handle(request) }
  }

  /// Registers a `CaptureActor` built after construction — ``EarsDaemon``
  /// calls this for a dynamically-created `browser:<label>` source (its
  /// first `ingest.open`) so `status`/`sources.list` see it without a
  /// restart. `EarsDaemon.captureActors` and this actor's own copy are two
  /// independent dictionaries (handed over by value at `start()`), so
  /// nothing added to one is visible from the other unless propagated
  /// explicitly — this is that propagation. Overwrites any existing entry
  /// for `id`, matching `openIngestSource(label:format:)`'s reuse-if-present
  /// semantics.
  public func registerDynamicSource(_ actor: CaptureActor, id: SourceID) {
    captureActors[id] = actor
  }

  /// Dispatch one decoded request to the owning actor and build its reply,
  /// per the routing table in this type's doc comment. Never throws: a thrown
  /// ``CaptureActorError`` / ``SessionRegistryError`` (or an unknown source id)
  /// is caught and rendered as an `ok:false` `ControlReply.failure(_:)`.
  public func handle(_ request: ControlRequest) async -> ControlReply {
    switch request {
    case .status:
      return await handleStatus()
    case .sourcesList:
      return await handleSourcesList()
    case .sourcesAdd:
      // Locked decision (see this type's doc comment / report): constructing a
      // brand-new source's live `CaptureBackend`/`CaptureActor` at runtime is
      // out of scope for Phase 1 (mic-only) and is a documented Phase-4 seam.
      // Rather than write an inert `meta.toml` for a source that would then be
      // absent from `status`/`sources.list` (no `CaptureActor` entry to report
      // it), this fails clearly instead of leaving a half-built source.
      return ControlReply(
        ControlResponse<EmptyData>.failure(
          "sources.add is not supported in this build (Phase 4 scope: runtime CaptureActor construction)"
        ))
    case .sourcesRemove(let source):
      return await handleSourcesRemove(source)
    case .sourcesEnable(let source):
      return await handleSourcesEnable(source)
    case .sourcesDisable(let source):
      return await handleSourcesDisable(source)
    case .capturePause(let source):
      return await handleCapturePause(source)
    case .captureResume(let source):
      return await handleCaptureResume(source)
    case .sessionOpen(let sources, let slug, let start, let vocab):
      return await handleSessionOpen(sources: sources, slug: slug, start: start, vocab: vocab)
    case .sessionClose(let id):
      return await handleSessionClose(id: id)
    case .sessionList:
      return await handleSessionList()
    case .mark(let sources, let slug, let range):
      return await handleMark(sources: sources, slug: slug, range: range)
    case .ingestOpen:
      // Browser ingest lives on the loopback WebSocket (`[earsd.ingest_ws]`),
      // not the privileged Unix control socket — see specs/transport.md.
      // Always fails clearly here rather than silently accepting a stream
      // this socket doesn't consume.
      return ControlReply(
        ControlResponse<IngestOpenData>.failure(
          "ingest.open is not supported on the control socket — use the WebSocket ingest endpoint"
        )
      )
    case .ingestClose:
      return ControlReply(
        ControlResponse<EmptyData>.failure(
          "ingest.close is not supported on the control socket — use the WebSocket ingest endpoint"
        )
      )
    case .segmentPublish(let session, let speaker, let start, let end, let text):
      // A pass-through to the live feed, not a new source of truth: no
      // session/source validation beyond the wire shape, no persistence —
      // the durable transcript is the on-disk file the publishing
      // `transcribe --follow` process writes itself.
      await eventSink?(
        .segment(session: session, speaker: speaker, start: start, end: end, text: text))
      return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
    case .flush:
      return await fanOut { try await $0.flush() }
    }
  }

  // MARK: - status / sources.list

  private func handleStatus() async -> ControlReply {
    let statuses = await collectStatuses()
    let uptime = max(0, Int(clock.now().interval(since: startInstant)))
    return ControlReply(
      ControlResponse<StatusData>.success(
        StatusData(uptimeSeconds: uptime, sources: statuses.map(SourceStatus.init))))
  }

  private func handleSourcesList() async -> ControlReply {
    let statuses = await collectStatuses()
    return ControlReply(
      ControlResponse<SourcesListData>.success(
        SourcesListData(sources: statuses.map(SourceStatus.init))))
  }

  /// Every source's domain status, in a deterministic (id-sorted) order —
  /// dictionary iteration order is otherwise unspecified.
  private func collectStatuses() async -> [CaptureSourceStatus] {
    var statuses: [CaptureSourceStatus] = []
    for (_, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      statuses.append(await actor.status())
    }
    return statuses
  }

  // MARK: - sources.remove / enable / disable

  private func handleSourcesRemove(_ source: SourceID) async -> ControlReply {
    guard let actor = captureActors[source] else {
      return ControlReply(ControlResponse<EmptyData>.failure(unknownSourceError(source)))
    }
    await actor.stop()
    captureActors[source] = nil
    // Ephemeral per `ActorContracts`: only this source's own `meta.toml` is
    // removed, never `config.toml`. Best-effort — a missing file is fine.
    try? FileManager.default.removeItem(
      at: DataStoreLayout.metaTomlFile(dataRoot: dataRoot, sourceID: source))
    return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
  }

  private func handleSourcesEnable(_ source: SourceID) async -> ControlReply {
    guard let actor = captureActors[source] else {
      return ControlReply(ControlResponse<EmptyData>.failure(unknownSourceError(source)))
    }
    do {
      try await actor.start()
      return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
    } catch {
      return ControlReply(ControlResponse<EmptyData>.failure(controlError(for: error)))
    }
  }

  private func handleSourcesDisable(_ source: SourceID) async -> ControlReply {
    guard let actor = captureActors[source] else {
      return ControlReply(ControlResponse<EmptyData>.failure(unknownSourceError(source)))
    }
    await actor.stop()
    return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
  }

  // MARK: - capture.pause / capture.resume

  private func handleCapturePause(_ source: SourceID?) async -> ControlReply {
    guard let source else {
      return await fanOut { try await $0.pause() }
    }
    guard let actor = captureActors[source] else {
      return ControlReply(ControlResponse<EmptyData>.failure(unknownSourceError(source)))
    }
    do {
      try await actor.pause()
      return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
    } catch {
      return ControlReply(ControlResponse<EmptyData>.failure(controlError(for: error)))
    }
  }

  private func handleCaptureResume(_ source: SourceID?) async -> ControlReply {
    guard let source else {
      return await fanOut { try await $0.resume() }
    }
    guard let actor = captureActors[source] else {
      return ControlReply(ControlResponse<EmptyData>.failure(unknownSourceError(source)))
    }
    do {
      try await actor.resume()
      return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
    } catch {
      return ControlReply(ControlResponse<EmptyData>.failure(controlError(for: error)))
    }
  }

  /// Runs `operation` against every source, in id-sorted order, collecting
  /// per-source failures rather than stopping at the first one — a `nil`
  /// source `capture.pause`/`capture.resume`, and `flush`, all fan out this
  /// way. Succeeds only if every source succeeded; otherwise the failure
  /// message names each failing source.
  private func fanOut(
    _ operation: (CaptureActor) async throws -> Void
  ) async -> ControlReply {
    var failures: [String] = []
    for (id, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      do {
        try await operation(actor)
      } catch {
        failures.append("\(id.rawValue): \(controlError(for: error).message)")
      }
    }
    guard failures.isEmpty else {
      return ControlReply(
        ControlResponse<EmptyData>.failure(ControlError(failures.joined(separator: "; "))))
    }
    return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
  }

  // MARK: - session.open / session.close / session.list / mark

  private func handleSessionOpen(
    sources: [SourceID], slug: String, start: Instant?, vocab: String?
  ) async -> ControlReply {
    do {
      let descriptor = try await sessions.open(
        sources: sources, slug: slug, start: start, vocab: vocab)
      return ControlReply(
        ControlResponse<SessionOpenData>.success(SessionOpenData(id: descriptor.id)))
    } catch {
      return ControlReply(ControlResponse<SessionOpenData>.failure(controlError(for: error)))
    }
  }

  private func handleSessionClose(id: String) async -> ControlReply {
    do {
      _ = try await sessions.close(id: id)
      return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
    } catch {
      return ControlReply(ControlResponse<EmptyData>.failure(controlError(for: error)))
    }
  }

  private func handleSessionList() async -> ControlReply {
    let summaries = await sessions.list().map(SessionSummary.init)
    return ControlReply(
      ControlResponse<SessionListData>.success(SessionListData(sessions: summaries)))
  }

  private func handleMark(
    sources: [SourceID], slug: String, range: MarkRange
  ) async -> ControlReply {
    do {
      let descriptor = try await sessions.mark(sources: sources, slug: slug, range: range)
      return ControlReply(
        ControlResponse<SessionOpenData>.success(SessionOpenData(id: descriptor.id)))
    } catch {
      return ControlReply(ControlResponse<SessionOpenData>.failure(controlError(for: error)))
    }
  }

  // MARK: - Error mapping

  private func unknownSourceError(_ id: SourceID) -> ControlError {
    ControlError("unknown source '\(id.rawValue)'")
  }

  /// Maps a thrown ``CaptureActorError``/``SessionRegistryError`` to a
  /// human-readable ``ControlError``; any other error (a backend/I-O failure)
  /// falls back to its description rather than being swallowed.
  private func controlError(for error: Error) -> ControlError {
    if let error = error as? CaptureActorError {
      switch error {
      case .alreadyCapturing:
        return "source is already capturing"
      case .notPaused:
        return "source is not paused"
      }
    }
    if let error = error as? SessionRegistryError {
      switch error {
      case .unknownSource(let id):
        return ControlError("unknown source '\(id.rawValue)'")
      case .noSources:
        return "at least one source is required"
      case .sessionNotFound(let id):
        return ControlError("no such session '\(id)'")
      case .sessionAlreadyClosed(let id):
        return ControlError("session '\(id)' is already closed")
      }
    }
    return ControlError("\(error)")
  }
}
