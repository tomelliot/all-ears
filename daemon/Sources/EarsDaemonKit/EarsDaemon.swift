import EarsCore
import EarsDataStore
import EarsIPC
import EarsLogging
import Foundation

/// Constructs the ``CaptureBackend`` for one configured source. `earsd`'s real
/// wiring supplies a factory that builds a real `EarsCaptureKit.MicCaptureBackend`
/// (or another class-backed backend per `descriptor.sourceClass`); tests supply
/// one that returns a `SyntheticCaptureBackend` or a scripted-failure fake, so
/// nothing in this type or its tests touches Core Audio or TCC.
public typealias CaptureBackendFactory = @Sendable (SourceDescriptor) -> any CaptureBackend

/// The resolved, ready-to-run shape of `[earsd]`/`[[earsd.source]]` config
/// (see `docs/configuration.md`) that ``EarsDaemon`` composes from. Building
/// this from a loaded `EarsdConfigSchema` config is a later (Wave 5) task's
/// job; this type is deliberately just a plain value the caller hands in.
public struct EarsDaemonConfiguration: Sendable {
  /// Every source to capture, already resolved from `[[earsd.source]]`.
  public var sources: [SourceDescriptor]
  /// `docs/configuration.md`'s `data_root`.
  public var dataRoot: URL
  /// `docs/configuration.md`'s `socket_path` (resolved, non-empty).
  public var socketPath: String
  /// `[earsd].chunk_seconds`.
  public var chunkSeconds: Double
  /// The VAD conformance shared across every source (Phase 1: always
  /// ``EnergyVAD``, per that type's doc comment).
  public var vad: EnergyVAD
  /// `[earsd].codec`/`.bitrate`/`.default_time_cap_seconds` — the same
  /// operator-configured storage defaults every config-declared source uses,
  /// reused for a dynamically-created `browser:<label>` source's on-disk
  /// encoding (see ``EarsDaemon/openIngestSource(label:format:)``). Every
  /// config-declared ``SourceDescriptor`` already has these baked in at
  /// resolution time; a browser source has no config entry to resolve one
  /// from, so ``EarsDaemon`` needs them directly.
  public var codec: String
  public var bitrate: Int
  public var defaultTimeCapSeconds: Int
  /// How often the daemon's ``EvictionSweeper`` runs its time-cap pass across
  /// every source, in seconds. The cap itself is per-source
  /// (`defaultTimeCapSeconds` / each source's `time_cap_seconds`); this only
  /// bounds how far past the cap a recording can linger before being expired
  /// (worst case ≈ cap + this interval). Default 60 s.
  public var evictionSweepIntervalSeconds: Double
  /// `[earsd.ingest_ws]`, or `nil` when disabled (the default) — gates
  /// whether ``EarsDaemon/start()`` also binds the loopback ingest
  /// WebSocket.
  public var ingestWebSocket: IngestWebSocketConfiguration?
  /// `[earsd.control_ws]`, or `nil` when disabled (the default) — gates
  /// whether ``EarsDaemon/start()`` also binds the loopback control-plane
  /// WebSocket (`EarsIPC.ControlWebSocketServer`).
  public var controlWebSocket: ControlWebSocketConfiguration?
  /// `[earsd.meetings].ingest_close_grace_s`: how long a browser meeting's
  /// last ingest stream may stay closed before the daemon ends the meeting
  /// (`reason = "ingest-idle"`). See `MeetingRegistry`'s orphan policy.
  public var meetingIngestCloseGraceSeconds: Double
  /// `[earsd.meetings].local_sources`: locally-captured source ids (your own
  /// mic, system audio) the daemon folds into every browser-triggered meeting
  /// at `meeting.start`, so your side is transcribed alongside the extension's
  /// per-participant streams. Filtered to sources that actually exist, so an
  /// id here that the daemon isn't capturing is silently skipped rather than
  /// breaking `transcribe --meeting`. Default `["mic"]`; `[]` disables.
  public var browserMeetingLocalSources: [SourceID]
  /// `[triggers]`/`[[triggers.rule]]`, resolved. Disabled (no rules) by
  /// default — gates whether ``EarsDaemon/start()`` also starts an
  /// ``AppSignalTriggerObserver``.
  public var triggers: TriggersConfiguration
  /// `docs/configuration.md`'s `output_root` — where `transcribe`/`cleanup`/
  /// `summarize` write. `earsd` itself never writes here; it's only needed
  /// to construct an `on_close` pipeline stage's file-path arguments (see
  /// ``AppSignalTriggerObserver``).
  public var outputRoot: URL

  public init(
    sources: [SourceDescriptor],
    dataRoot: URL,
    socketPath: String,
    chunkSeconds: Double = 30,
    vad: EnergyVAD = EnergyVAD(),
    codec: String = "aac",
    bitrate: Int = 64_000,
    defaultTimeCapSeconds: Int = 7_200,
    evictionSweepIntervalSeconds: Double = 60,
    ingestWebSocket: IngestWebSocketConfiguration? = nil,
    controlWebSocket: ControlWebSocketConfiguration? = nil,
    meetingIngestCloseGraceSeconds: Double = 120,
    browserMeetingLocalSources: [SourceID] = ["mic"],
    triggers: TriggersConfiguration = TriggersConfiguration(),
    outputRoot: URL = URL(fileURLWithPath: ".")
  ) {
    self.sources = sources
    self.dataRoot = dataRoot
    self.socketPath = socketPath
    self.chunkSeconds = chunkSeconds
    self.vad = vad
    self.codec = codec
    self.bitrate = bitrate
    self.outputRoot = outputRoot
    self.defaultTimeCapSeconds = defaultTimeCapSeconds
    self.evictionSweepIntervalSeconds = evictionSweepIntervalSeconds
    self.ingestWebSocket = ingestWebSocket
    self.controlWebSocket = controlWebSocket
    self.meetingIngestCloseGraceSeconds = meetingIngestCloseGraceSeconds
    self.browserMeetingLocalSources = browserMeetingLocalSources
    self.triggers = triggers
  }
}

/// `[earsd.ingest_ws]`'s resolved shape: the loopback port to bind and the
/// Origin allowlist to enforce before completing a WebSocket upgrade. See
/// `EarsIPC.IngestWebSocketServer`.
public struct IngestWebSocketConfiguration: Sendable {
  public var port: UInt16
  /// Empty rejects every connection (fail closed) — never "allow all".
  public var allowedOrigins: [String]

  public init(port: UInt16, allowedOrigins: [String]) {
    self.port = port
    self.allowedOrigins = allowedOrigins
  }
}

/// `[earsd.control_ws]`'s resolved shape — mirrors
/// ``IngestWebSocketConfiguration`` exactly (loopback port + fail-closed
/// Origin allowlist), for the control-plane WebSocket. See
/// `EarsIPC.ControlWebSocketServer`.
public struct ControlWebSocketConfiguration: Sendable {
  public var port: UInt16
  /// Empty rejects every connection (fail closed) — never "allow all".
  public var allowedOrigins: [String]

  public init(port: UInt16, allowedOrigins: [String]) {
    self.port = port
    self.allowedOrigins = allowedOrigins
  }
}

/// The top-level composition: wires one ``CaptureActor`` per configured
/// source, a ``SessionRegistry``, a ``ControlServer`` serving the real control
/// socket, an ``EventBus`` bridging both event producers to the socket's
/// pub/sub fan-out, a ``PowerObserver``, and a ``ShutdownCoordinator`` into one
/// runnable daemon — the object `earsd`'s `main` constructs and runs.
///
/// This is integration/wiring only: every real behavior already lives in the
/// five collaborators this type composes. An `actor` since ``start()``/``stop()``
/// mutate its own lifecycle state (the running socket server, the power
/// observer) and must not race a concurrent call.
public actor EarsDaemon {
  private let configuration: EarsDaemonConfiguration
  private let clock: any NowProviding
  /// The one structured sink every part of the daemon logs through — the
  /// capture path (via each ``CaptureActor``) and the lifecycle/component
  /// string logs (via ``log``, which wraps this). One sink means one
  /// consistent JSON-Lines + stderr + unified-logging fan-out everywhere.
  private let logSink: any LogRecordSink
  /// The daemon's free-text lifecycle/component logger, threaded into
  /// `ControlServer`, `MeetingRegistry`, `OnClosePipelineRunner`, etc. Now a
  /// thin wrapper over ``logSink`` (built in `init`) so those messages land in
  /// the same stream as everything else, rather than a separate path.
  private let log: @Sendable (String) -> Void

  /// Every source's live ``CaptureActor``. Empty at boot: the daemon builds and
  /// starts a source's actor only when a meeting that names it starts (config
  /// sources, via ``startMeetingCapture(meetingID:sources:)``) or on its first
  /// `ingest.open` (browser sources), and tears it down when the last meeting
  /// referencing it ends (or its ingest stream closes).
  private var captureActors: [SourceID: CaptureActor]
  /// The config-declared sources' descriptors, kept for on-demand capture. A
  /// meeting names a source id; this is where its capture parameters (rates,
  /// codec, device uid) are resolved from when the actor is built. Browser
  /// sources have no entry here — they're built by ``openIngestSource`` from
  /// the ingest format instead.
  private let configuredDescriptors: [SourceID: SourceDescriptor]
  /// Builds a config source's real capture backend on demand — stored so a
  /// meeting can construct actors after the daemon has already started.
  private let backendFactory: CaptureBackendFactory
  /// Which live meetings currently reference each config source's capture. A
  /// source records while this set is non-empty and is stopped and torn down
  /// once it empties, so two concurrent meetings sharing the mic keep it alive
  /// until both end.
  private var captureMeetingRefs: [SourceID: Set<String>] = [:]
  /// The producer→subscriber bridge for live-feed events: every
  /// ``CaptureActor`` and the ``SessionRegistry`` publish into it from
  /// construction on, and ``start()`` attaches the socket server's fan-out
  /// once the listener is bound (see ``EventBus``'s lifetime rationale).
  private let eventBus: EventBus
  private var controlSocketServer: ControlSocketServer?
  private var controlServerRunTask: Task<Void, Never>?
  private var controlServer: ControlServer?
  private var controlWebSocketServer: ControlWebSocketServer?
  private var controlWebSocketRunTask: Task<Void, Never>?
  private var meetingRegistry: MeetingRegistry?
  /// Fresh per daemon start, advertised in every `hello` result — what tells
  /// a reconnecting client the revision counters reset.
  private let bootID = UUID().uuidString.lowercased()
  private var powerObserver: PowerObserver?
  private var appSignalTriggerObserver: AppSignalTriggerObserver?
  /// The daemon-owned, timer-driven time-cap enforcer — expires aged-out
  /// recordings across every source independent of capture activity. Started in
  /// ``start()`` after the control socket is bound, stopped in ``stop()``.
  private var evictionSweeper: EvictionSweeper?

  // MARK: - Dynamic browser (ingest) sources
  //
  // Unlike config-declared sources (built once in init(), fixed for the
  // daemon's lifetime), a browser:<label> source is built lazily on its
  // first ingest.open — see openIngestSource(label:format:). Once built it
  // joins `captureActors` like any other source (so status/sources.list see
  // it for free); `pushBackends` and `ingestStreams` are the extra state
  // only dynamic sources need.

  /// The push backend behind each dynamically-created source, keyed the
  /// same as `captureActors` — needed because `CaptureActor` only exposes
  /// its backend as `any CaptureBackend`, with no way back to the concrete
  /// `PushCaptureBackend` a WebSocket push needs to feed.
  private var pushBackends: [SourceID: PushCaptureBackend] = [:]
  /// stream_id → the label it was opened for. stream_ids are per-open-call
  /// (not per-label): the same label can be opened, closed, and reopened
  /// many times over the daemon's life (a participant leaving and
  /// rejoining), each time reusing the same underlying CaptureActor/backend
  /// — mirroring sources.enable/disable on a persistent actor — while each
  /// individual `ingest.open` still gets its own fresh id to route binary
  /// frames and a later `ingest.close` by.
  private var ingestStreams: [String: SourceID] = [:]
  private var nextIngestStreamID = 0
  private var ingestWebSocketServer: IngestWebSocketServer?
  private var ingestServerRunTask: Task<Void, Never>?

  /// Thrown by ``openIngestSource(label:format:)`` for a `source` that isn't
  /// a `browser:*` id — guards against a WebSocket client naming an
  /// existing config-declared source (e.g. `mic`) and hijacking its
  /// `CaptureActor`.
  public enum IngestError: Error, Sendable {
    case notABrowserSource(SourceID)
  }

  /// Records `configuration` and boots **idle**: no `CaptureActor` is built,
  /// no source directory or `meta.toml` is written, and no backend or socket
  /// is started until ``start()`` — and even then capture stays off until a
  /// meeting starts. Recording is meeting-scoped, so a source's actor is built
  /// and started only when a meeting names it (see
  /// ``startMeetingCapture(meetingID:sources:)``) or on its first `ingest.open`.
  ///
  /// - Parameter logSink: The single structured sink the whole daemon logs
  ///   through — capture events, lifecycle, and every component's free-text
  ///   log. Defaults to ``NoOpLogRecordSink`` so a caller (or test) that
  ///   doesn't wire logging still constructs cleanly; `EarsdRuntime` passes
  ///   the real `LogSink` built from config.
  public init(
    configuration: EarsDaemonConfiguration,
    backendFactory: @escaping CaptureBackendFactory,
    clock: any NowProviding = SystemClock(),
    logSink: any LogRecordSink = NoOpLogRecordSink()
  ) throws {
    self.configuration = configuration
    self.clock = clock
    self.logSink = logSink
    self.backendFactory = backendFactory
    self.configuredDescriptors = Dictionary(
      configuration.sources.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

    // The free-text lifecycle/component logger is a thin wrapper over the one
    // sink: each message becomes a `daemon.log` record carrying it, so these
    // land in the same JSON-Lines + stderr + unified stream as the structured
    // capture and CLI records. Fire-and-forget (the closure is synchronous and
    // reused across sync/async call sites); ordering isn't guaranteed for these
    // operational lines, which is acceptable — anything requiring ordered flush
    // (shutdown) logs through the sink directly in `EarsdRuntime`.
    let pid = ProcessInfo.processInfo.processIdentifier
    self.log = { message in
      let record = LogRecord(
        ts: clock.now(), level: .notice, tool: "earsd",
        subsystem: "net.tomelliot.ears", category: "earsd", pid: pid,
        event: "daemon.log", msg: message)
      Task { try? await logSink.log(record) }
    }

    let eventBus = EventBus()
    self.eventBus = eventBus

    // Idle boot: no capture actor is built, and nothing is written to disk,
    // until a meeting starts (see `startMeetingCapture`) or an `ingest.open`
    // creates a browser source. A fresh daemon start therefore writes no audio
    // and creates no source directories.
    self.captureActors = [:]
  }

  /// Builds one source's `CaptureActor` — and its `ChunkEncoder`/
  /// `IndexAppender`/on-disk directory/`meta.toml` — from `descriptor`. The
  /// construction logic every config-declared source goes through at
  /// `init()`, and the same logic ``openIngestSource(label:format:)`` uses
  /// to build a `browser:<label>` source the first time it's ever seen.
  private static func buildCaptureActor(
    for descriptor: SourceDescriptor,
    configuration: EarsDaemonConfiguration,
    backend: any CaptureBackend,
    clock: any NowProviding,
    eventSink: EventSink?,
    logSink: any LogRecordSink
  ) throws -> CaptureActor {
    let sourceDirectory = DataStoreLayout.sourceDirectory(
      dataRoot: configuration.dataRoot, sourceID: descriptor.id)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)

    try writeSourceMeta(descriptor, dataRoot: configuration.dataRoot)

    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.structuralIndexFile(
        dataRoot: configuration.dataRoot, sourceID: descriptor.id))
    let vadWriter = VADSegmentWriter(
      directory: DataStoreLayout.vadDirectory(
        dataRoot: configuration.dataRoot, sourceID: descriptor.id))
    let encoder = try ChunkEncoder(
      sourceID: descriptor.id,
      dataRoot: configuration.dataRoot,
      codec: descriptor.codec,
      bitrate: descriptor.bitrate,
      nativeSampleRate: descriptor.nativeSampleRate,
      asrSampleRate: descriptor.asrSampleRate,
      storeNative: descriptor.storeNative,
      chunkSeconds: configuration.chunkSeconds,
      startInstant: clock.now(),
      indexAppender: indexAppender)

    return CaptureActor(
      descriptor: descriptor,
      dataRoot: configuration.dataRoot,
      backend: backend,
      encoder: encoder,
      indexAppender: indexAppender,
      vadWriter: vadWriter,
      vad: configuration.vad,
      clock: clock,
      eventSink: eventSink,
      logSink: logSink)
  }

  /// Persists `descriptor` to `<data-root>/sources/<id>/meta.toml` via
  /// ``SourceMetaStore``, so every source `earsd` actually runs has a real
  /// `meta.toml` on disk from the start -- ``SegmentedAudioReader`` (and
  /// anything else resolving a source's ASR rate) depends on
  /// ``SourceMetaStore/read(sourceID:dataRoot:)`` finding one.
  ///
  /// Idempotent and non-clobbering across restarts: a fresh config-resolution
  /// pass stamps every descriptor's `created` with the current daemon-start
  /// instant (`docs/data-formats.md`'s "always present" descriptor, not
  /// "always freshly created"), so writing `descriptor` verbatim on every
  /// restart would reset a source's true creation time each time `earsd`
  /// restarts. When a `meta.toml` already exists, this keeps its `created`
  /// and writes everything else from `descriptor` -- so config edits (e.g. a
  /// changed `time_cap_seconds`) still take effect on restart, without
  /// clobbering the one field that records history.
  private static func writeSourceMeta(_ descriptor: SourceDescriptor, dataRoot: URL) throws {
    var toWrite = descriptor
    do {
      let existing = try SourceMetaStore.read(sourceID: descriptor.id, dataRoot: dataRoot)
      toWrite.created = existing.created
    } catch DataStoreError.sourceMetaNotFound {
      // First time this source has been seen: write `descriptor` as-is,
      // `created` and all.
    }
    try SourceMetaStore.write(toWrite, dataRoot: dataRoot)
  }

  /// Starts every configured source, then the control socket and power
  /// observer.
  ///
  /// **Per-source startup failure isolation** (`docs/specs/capture-daemon.md`:
  /// "missing permission for a source logs an error and disables just that
  /// source — never takes down the daemon"): each source's `CaptureActor.start()`
  /// is tried independently; a throwing source is logged and left in its
  /// actor's `.error` state (`CaptureActor.start()` already sets this before
  /// rethrowing), and every other source still starts. This method itself
  /// only throws for the socket listener failing to bind — a genuinely
  /// daemon-fatal condition, unlike one source's permission denial.
  public func start() async throws {

    // `knownSourceIDs` is a *live* lookup back into this actor, not a
    // snapshot of `captureActors`: a `browser:<label>` source built by a
    // later `ingest.open` (see `openIngestSource(label:format:)`) must be
    // nameable by a session opened at any point afterwards. `[weak self]`
    // because this daemon retains the registry (via `controlServer`), and a
    // strong capture here would cycle; a deallocated daemon has no sources.
    let sessions = SessionRegistry(
      dataRoot: configuration.dataRoot,
      knownSourceIDs: { [weak self] in
        guard let self else { return [] }
        return await self.currentSourceIDs()
      },
      clock: clock,
      eventSink: { [eventBus] event in await eventBus.publish(event) })
    // The daemon-owned meeting lifecycle registry, serving the `meeting.*`
    // verbs on both control transports. Meeting end fires the meeting-level
    // auto-transcribe (gated the same way as the v1 per-session hook).
    let onMeetingEnded: MeetingRegistry.EndedHook?
    if configuration.triggers.transcribeOnBrowserSessionClose {
      let pipeline = OnClosePipelineRunner(outputRoot: configuration.outputRoot, log: log)
      onMeetingEnded = { meeting, _ in
        guard meeting.trigger == .browserExtension else { return }
        Task {
          await pipeline.runMeetingTranscribe(meetingID: meeting.id, context: "meeting-end")
        }
      }
    } else {
      onMeetingEnded = nil
    }
    let meetings = MeetingRegistry(
      dataRoot: configuration.dataRoot,
      clock: clock,
      bus: eventBus,
      graceSeconds: configuration.meetingIngestCloseGraceSeconds,
      onEnded: onMeetingEnded,
      localBrowserSources: configuration.browserMeetingLocalSources,
      knownSourceIDs: { [weak self] in
        guard let self else { return [] }
        return await self.currentSourceIDs()
      },
      startCapture: { [weak self] meetingID, sources in
        await self?.startMeetingCapture(meetingID: meetingID, sources: sources)
      },
      stopCapture: { [weak self] meetingID, sources in
        await self?.stopMeetingCapture(meetingID: meetingID, sources: sources)
      },
      log: log)
    // `loadFromDisk()` is deferred to after `self.controlServer` is assigned
    // below: a meeting still active on disk resumes capture through
    // `startMeetingCapture`, which registers the rebuilt source into the
    // control server so `status`/`sources.list` see it.
    meetingRegistry = meetings

    // Browser-triggered on-close transcribe: the browser extension has no
    // app-signal rule to hang a rule's `on_close` off, so a session closed
    // with `trigger == .browserExtension` runs the transcribe stage directly
    // — gated by `[triggers].transcribe_on_browser_session_close`, and
    // spawned in its own task so the `session.close` reply is never blocked
    // behind a full transcription run.
    let onSessionClosed: (@Sendable (SessionDescriptor) async -> Void)?
    if configuration.triggers.transcribeOnBrowserSessionClose {
      let pipeline = OnClosePipelineRunner(outputRoot: configuration.outputRoot, log: log)
      onSessionClosed = { descriptor in
        guard descriptor.trigger == .browserExtension else { return }
        Task {
          await pipeline.run(
            stages: ["transcribe"], for: descriptor, context: "browser-session-close")
        }
      }
    } else {
      onSessionClosed = nil
    }

    let controlServer = ControlServer(
      captureActors: captureActors,
      sessions: sessions,
      dataRoot: configuration.dataRoot,
      startInstant: clock.now(),
      clock: clock,
      // `segment.publish`/`job.publish` → the live feed, and `subscribe`
      // snapshots read the bus's revision.
      bus: eventBus,
      meetings: meetings,
      onSessionClosed: onSessionClosed)

    let socketDirectory = URL(fileURLWithPath: configuration.socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: socketDirectory, withIntermediateDirectories: true)

    let identity = ControlServerIdentity(daemon: "earsd 0.1.0", bootID: bootID)
    let listener = try await NetworkSocketListener.bind(toPath: configuration.socketPath)
    let socketServer = ControlSocketServer(
      listener: listener, identity: identity, log: log, handler: controlServer.makeHandler())
    controlSocketServer = socketServer
    controlServerRunTask = Task { await socketServer.run() }
    // Kept so `openIngestSource`/`startMeetingCapture` can register a
    // dynamically-built source into this SAME actor's `captureActors` —
    // otherwise it's a value-type copy neither sees the other's later changes
    // to. No capture is started here: the daemon boots idle and starts
    // recording only when a meeting begins.
    self.controlServer = controlServer

    // Now that the control server is wired, recover any meeting still active
    // on disk — resuming capture of its sources through `startMeetingCapture`.
    await meetings.loadFromDisk()

    // The loopback control-plane WebSocket serves the SAME handler as the
    // Unix socket — zero duplicated command dispatch between transports.
    // Started before the event-bus attach below so its subscribers join the
    // same fan-out.
    if let controlWebSocket = configuration.controlWebSocket {
      await startControlWebSocket(
        controlWebSocket, identity: identity, handler: controlServer.makeHandler())
    }
    let controlWebSocketServer = self.controlWebSocketServer

    // Only started when configured with at least one rule -- disabled (the
    // default) means no observer, no subscription, no behavior change from
    // before this existed.
    let triggerObserver: AppSignalTriggerObserver?
    if configuration.triggers.enabled, !configuration.triggers.rules.isEmpty {
      let observer = AppSignalTriggerObserver(
        rules: configuration.triggers.rules,
        sessions: sessions,
        outputRoot: configuration.outputRoot,
        log: log)
      await observer.start()
      appSignalTriggerObserver = observer
      triggerObserver = observer
    } else {
      triggerObserver = nil
    }

    // Only now does a pub/sub consumer exist: route every event published by
    // the capture actors / session registry into the socket's fan-out (and,
    // when configured, the app-signal trigger observer's own vad-event
    // correlation). Events published before this line (during source
    // startup) were dropped by design — no subscriber could have been
    // connected yet anyway.
    await eventBus.attach { frame in
      await socketServer.publish(frame)
      await controlWebSocketServer?.publish(frame)
      await triggerObserver?.handle(frame.event)
    }

    // Capture is meeting-scoped, so the set of live actors changes over the
    // daemon's lifetime — the observer reads it live rather than snapshotting
    // an (empty at boot) map, so sleep/wake pauses whatever is recording for
    // the active meeting.
    let observer = PowerObserver(activeCaptureActors: { [weak self] in
      await self?.currentPausables() ?? []
    })
    await observer.startObserving()
    powerObserver = observer

    // The daemon owns time-cap enforcement: a periodic sweep over every source
    // on disk, decoupled from capture so stopped/idle sources (an ended meeting,
    // a disabled source) are expired too — not just the continuously-capturing
    // mic. `[weak self]` to avoid a retain cycle (the daemon owns the sweeper).
    let sweeper = EvictionSweeper(
      dataRoot: configuration.dataRoot,
      clock: clock,
      intervalSeconds: configuration.evictionSweepIntervalSeconds,
      log: log,
      evictThroughActors: { [weak self] ids in
        guard let self else { return [] }
        return await self.evictThroughLiveActors(ids)
      })
    await sweeper.start()
    evictionSweeper = sweeper

    if let ingestWebSocket = configuration.ingestWebSocket {
      await startIngestWebSocket(ingestWebSocket)
    }
  }

  /// Evicts each id that has a live `CaptureActor` through that actor (so the
  /// actor's shared `IndexAppender` stays the single writer to its index), and
  /// returns the ids it handled. The ``EvictionSweeper`` disk-evicts the rest.
  private func evictThroughLiveActors(_ ids: Set<SourceID>) async -> Set<SourceID> {
    var handled: Set<SourceID> = []
    for id in ids {
      guard let actor = captureActors[id] else { continue }
      await actor.evictNow()
      handled.insert(id)
    }
    return handled
  }

  /// Binds and starts the ingest WebSocket. A bind failure (e.g. the port is
  /// already in use) is logged and leaves ingest disabled for this run,
  /// exactly like a capture source's own startup failure — it must never
  /// take down local capture, which `start()`'s caller has no reason to
  /// expect a browser-ingest port conflict to affect.
  private func startIngestWebSocket(_ ingestWebSocket: IngestWebSocketConfiguration) async {
    let ingestListener: NetworkSocketListener
    do {
      ingestListener = try await NetworkSocketListener.bind(toLoopbackPort: ingestWebSocket.port)
    } catch {
      log("ingest websocket failed to bind port \(ingestWebSocket.port) and is disabled: \(error)")
      return
    }
    let ingestServer = IngestWebSocketServer(
      listener: ingestListener,
      allowedOrigins: ingestWebSocket.allowedOrigins,
      log: log,
      onOpen: { [weak self] label, format, meeting in
        guard let self else { throw IngestError.notABrowserSource(label) }
        return try await self.openIngestSource(label: label, format: format, meeting: meeting)
      },
      onPush: { [weak self] streamID, samples, sampleRate in
        await self?.pushIngestAudio(streamID: streamID, samples: samples, sampleRate: sampleRate)
      },
      onClose: { [weak self] streamID in
        await self?.closeIngestSource(streamID: streamID)
      })
    ingestWebSocketServer = ingestServer
    ingestServerRunTask = Task { await ingestServer.run() }
  }

  /// Binds and starts the control-plane WebSocket. Same bind-failure
  /// isolation as ``startIngestWebSocket(_:)``: a port conflict is logged and
  /// leaves the control WebSocket disabled for this run — it must never take
  /// down local capture (the isolation that was itself a bugfix for ingest,
  /// journal #36/#37).
  private func startControlWebSocket(
    _ controlWebSocket: ControlWebSocketConfiguration,
    identity: ControlServerIdentity,
    handler: @escaping ControlHandler
  ) async {
    let controlListener: NetworkSocketListener
    do {
      controlListener = try await NetworkSocketListener.bind(toLoopbackPort: controlWebSocket.port)
    } catch {
      log(
        "control websocket failed to bind port \(controlWebSocket.port) and is disabled: \(error)")
      return
    }
    let server = ControlWebSocketServer(
      listener: controlListener,
      allowedOrigins: controlWebSocket.allowedOrigins,
      identity: identity,
      log: log,
      handler: handler)
    controlWebSocketServer = server
    controlWebSocketRunTask = Task { await server.run() }
  }

  /// Stops the control socket and power observer, then every source, in
  /// reverse order — no new commands can arrive mid-shutdown, and each
  /// source's in-progress chunk is flushed and indexed (``CaptureActor/stop()``'s
  /// contract) before this returns.
  public func stop() async {
    // Detach the event fan-out first so no capture actor's publish races the
    // socket server's teardown; events published during shutdown are dropped
    // (the bus's documented unattached behavior).
    await eventBus.detach()
    if let controlSocketServer {
      await controlSocketServer.shutdown()
    }
    controlServerRunTask?.cancel()
    controlServerRunTask = nil
    controlSocketServer = nil
    controlServer = nil

    if let controlWebSocketServer {
      await controlWebSocketServer.shutdown()
    }
    controlWebSocketRunTask?.cancel()
    controlWebSocketRunTask = nil
    controlWebSocketServer = nil
    meetingRegistry = nil

    if let ingestWebSocketServer {
      await ingestWebSocketServer.shutdown()
    }
    ingestServerRunTask?.cancel()
    ingestServerRunTask = nil
    self.ingestWebSocketServer = nil

    if let evictionSweeper {
      await evictionSweeper.stop()
    }
    evictionSweeper = nil

    if let powerObserver {
      await powerObserver.stopObserving()
    }
    powerObserver = nil

    if let appSignalTriggerObserver {
      await appSignalTriggerObserver.stop()
    }
    appSignalTriggerObserver = nil

    for actor in captureActors.values {
      await actor.stop()
    }
  }

  // MARK: - Dynamic browser (ingest) sources

  /// `ingest.open`: find-or-build the `CaptureActor` for `label`, (re)start
  /// it, and mint a fresh `stream_id` for this open call.
  ///
  /// First-time construction is deferred to a label's first `ingest.open` —
  /// there is no config entry to resolve a `browser:<label>` source from
  /// ahead of time. A label that already has a `CaptureActor` (from a prior
  /// open within this daemon's lifetime) is reused and (re)started rather
  /// than rebuilt, mirroring `sources.enable`'s semantics on a persistent
  /// actor: a participant who leaves and rejoins resumes the SAME on-disk
  /// source instead of fragmenting into a new one, and `CaptureActor.start()`
  /// throwing `.alreadyCapturing` (a second concurrent open for a still-live
  /// stream) is treated as success, not an error.
  ///
  /// The declared `format` becomes the source's native *and* ASR rate (no
  /// separate higher-quality feed exists for browser-ingested audio — the
  /// extension already resamples to 16 kHz before sending), so `storeNative`
  /// is `false`: storing a second identical-rate copy under `chunks/` would
  /// just duplicate `asr/`'s bytes for nothing. `ChunkResampler` accepts an
  /// equal native/ASR rate fine (verified: it builds an `AVAudioConverter`
  /// with ratio 1.0, not a special-cased failure).
  ///
  /// Visibility of a dynamically-created source elsewhere in the daemon:
  /// `ControlServer`'s map is kept in sync via `registerDynamicSource`
  /// (`status`/`sources.list`), and `SessionRegistry.knownSourceIDs` is a
  /// live lookup back into this actor (see `start()`), so a session opened
  /// at any point can name a browser source created by a later
  /// `ingest.open`. Known remaining gap: `PowerObserver` still holds the
  /// `captureActors` *snapshot* it was built with at `start()`, so a
  /// dynamic source created afterwards is not paused/resumed on sleep/wake
  /// — a documented follow-up (Phase 6 scoped it out as separable), not
  /// silently assumed fixed.
  public func openIngestSource(
    label: SourceID, format: AudioFormatSpec, meeting: MeetingIdentity? = nil
  ) async throws -> String {
    guard label.sourceClass == .browser else {
      throw IngestError.notABrowserSource(label)
    }

    let actor: CaptureActor
    if let existing = captureActors[label] {
      actor = existing
    } else {
      let descriptor = SourceDescriptor(
        schema: 1,
        id: label,
        sourceClass: .browser,
        label: "",
        deviceUID: "",
        nativeSampleRate: format.sampleRate,
        asrSampleRate: format.sampleRate,
        storeNative: false,
        channels: format.channels,
        codec: configuration.codec,
        bitrate: configuration.bitrate,
        timeCapSeconds: configuration.defaultTimeCapSeconds,
        created: clock.now())
      let backend = PushCaptureBackend(source: label)
      let built = try Self.buildCaptureActor(
        for: descriptor,
        configuration: configuration,
        backend: backend,
        clock: clock,
        eventSink: { [eventBus] event in await eventBus.publish(event) },
        logSink: logSink)
      captureActors[label] = built
      pushBackends[label] = backend
      await controlServer?.registerDynamicSource(built, id: label)
      actor = built
    }

    do {
      try await actor.start()
    } catch CaptureActorError.alreadyCapturing {
      // Already running — a second open for a still-live stream is a no-op.
    }

    nextIngestStreamID += 1
    let streamID = "s\(nextIngestStreamID)"
    ingestStreams[streamID] = label
    // Feed the meeting registry's orphan-grace tracking: a live stream on a
    // meeting's source cancels its pending grace expiry. The membership tag
    // (when the extension sent one) links the source into its meeting
    // daemon-side, so the grace policy holds even if the client's attendee
    // upserts never arrive.
    await meetingRegistry?.ingestStreamOpened(source: label, meeting: meeting)
    return streamID
  }

  /// Routes one decoded PCM buffer to the `CaptureActor` behind `streamID`,
  /// via its `PushCaptureBackend`. An unknown `streamID` (already closed, or
  /// never opened) drops the buffer silently — the WebSocket layer already
  /// logs that case once per frame.
  public func pushIngestAudio(streamID: String, samples: [Float], sampleRate: Int) async {
    guard let label = ingestStreams[streamID], let backend = pushBackends[label] else { return }
    await backend.push(AudioBuffer(samples: samples, sampleRate: sampleRate))
  }

  /// `ingest.close`: stop the `CaptureActor` behind `streamID` (flushing and
  /// indexing its in-progress chunk, same as `sources.disable`) and forget
  /// the stream_id → label mapping. The actor itself, and its `meta.toml`,
  /// are left in place — a later `ingest.open` for the same label resumes
  /// them rather than starting over.
  public func closeIngestSource(streamID: String) async {
    guard let label = ingestStreams.removeValue(forKey: streamID) else { return }
    if let actor = captureActors[label] {
      await actor.stop()
    }
    // When this was a browser meeting's last live stream, its ingest-close
    // grace clock starts now.
    await meetingRegistry?.ingestStreamClosed(source: label)
  }

  /// The ids of every source this daemon currently knows — the config-declared
  /// sources (whether or not they're capturing right now) plus any live
  /// `browser:<label>` sources built by `ingest.open` — read live for
  /// ``SessionRegistry``/``MeetingRegistry``'s `knownSourceIDs` validation
  /// seam. Config sources stay "known" while idle so a meeting can still fold
  /// in `local_sources` (the mic) before any actor exists.
  private func currentSourceIDs() -> Set<SourceID> {
    Set(configuredDescriptors.keys).union(captureActors.keys)
  }

  /// Every currently-live capture actor as a ``SuspendablePauseResume``, for
  /// the ``PowerObserver``'s live view — read on each sleep/wake transition so
  /// it pauses/resumes exactly what a meeting is recording right now.
  private func currentPausables() -> [any SuspendablePauseResume] {
    Array(captureActors.values)
  }

  // MARK: - Meeting-scoped capture

  /// Starts capture for the config-declared sources a meeting names,
  /// ref-counted by meeting id so a source shared by concurrent meetings keeps
  /// recording until the last one ends. Browser (`browser:*`) and unknown ids
  /// have no ``configuredDescriptors`` entry and are skipped — browser sources
  /// are driven by their ingest streams, not the meeting controller.
  /// Idempotent per meeting: re-declaring a meeting only starts sources it
  /// hasn't already claimed.
  func startMeetingCapture(meetingID: String, sources: [SourceID]) async {
    for id in sources {
      guard let descriptor = configuredDescriptors[id] else { continue }
      let wasIdle = (captureMeetingRefs[id]?.isEmpty ?? true)
      captureMeetingRefs[id, default: []].insert(meetingID)
      guard wasIdle else { continue }
      await ensureCaptureStarted(descriptor)
    }
  }

  /// Releases a meeting's hold on its config sources; a source with no
  /// remaining meeting is stopped (flushing its in-progress chunk) and torn
  /// down. Browser/unknown ids are skipped, as in ``startMeetingCapture``.
  func stopMeetingCapture(meetingID: String, sources: [SourceID]) async {
    for id in sources {
      guard configuredDescriptors[id] != nil else { continue }
      guard captureMeetingRefs[id]?.remove(meetingID) != nil else { continue }
      if captureMeetingRefs[id]?.isEmpty ?? true {
        captureMeetingRefs[id] = nil
        await teardownCaptureActor(id)
      }
    }
  }

  /// Builds (if needed) and starts a config source's `CaptureActor`, registering
  /// a freshly-built one into the control server so `status`/`sources.list` see
  /// it. A build failure disables just that source (logged), and a backend
  /// `start()` failure leaves it in `.error` — never taking down the meeting or
  /// the daemon, mirroring the old per-source startup isolation.
  private func ensureCaptureStarted(_ descriptor: SourceDescriptor) async {
    let actor: CaptureActor
    if let existing = captureActors[descriptor.id] {
      actor = existing
    } else {
      do {
        actor = try Self.buildCaptureActor(
          for: descriptor,
          configuration: configuration,
          backend: backendFactory(descriptor),
          clock: clock,
          eventSink: { [eventBus] event in await eventBus.publish(event) },
          logSink: logSink)
      } catch {
        log(
          "meeting capture: source '\(descriptor.id.rawValue)' failed to build and is disabled: \(error)"
        )
        return
      }
      captureActors[descriptor.id] = actor
      await controlServer?.registerDynamicSource(actor, id: descriptor.id)
    }
    do {
      try await actor.start()
    } catch CaptureActorError.alreadyCapturing {
      // Already running for another meeting — nothing to do.
    } catch {
      log("meeting capture: source '\(descriptor.id.rawValue)' failed to start: \(error)")
    }
  }

  /// Stops a config source's actor and removes it from the live set and the
  /// control server. Its `meta.toml` and captured audio are left on disk —
  /// transcription and retention still need them; the daemon just stops holding
  /// the actor.
  private func teardownCaptureActor(_ id: SourceID) async {
    guard let actor = captureActors[id] else { return }
    await actor.stop()
    captureActors[id] = nil
    await controlServer?.unregisterDynamicSource(id: id)
  }

  /// Every source's current status, keyed by id — a test-only seam so an
  /// end-to-end test can assert on capture state directly, without going
  /// through the control socket (a separate real-socket test already proves
  /// that path works).
  func statusForTesting() async -> [SourceID: CaptureSourceStatus] {
    var statuses: [SourceID: CaptureSourceStatus] = [:]
    for (id, actor) in captureActors {
      statuses[id] = await actor.status()
    }
    return statuses
  }

  /// Test-only: drive the meeting lifecycle through the daemon's real
  /// ``MeetingRegistry``, so an end-to-end test can assert capture starts and
  /// stops on meeting boundaries without a socket round-trip (a separate
  /// real-socket path already proves the control plane). Both call the exact
  /// registry entry points `meeting.start`/`meeting.end` route to.
  func startMeetingForTesting(_ params: MeetingStartParams) async throws -> Meeting {
    guard let meetingRegistry else {
      fatalError("startMeetingForTesting called before start()")
    }
    return try await meetingRegistry.start(params)
  }

  @discardableResult
  func endMeetingForTesting(id: String) async throws -> Meeting? {
    guard let meetingRegistry else { return nil }
    return try await meetingRegistry.end(id: id)
  }

  /// The socket server's current subscriber count — a test-only seam so an
  /// end-to-end test can wait for its `subscribe` to be registered before
  /// triggering the events it expects to receive (the same handshake
  /// `EarsIPCTests/NetworkTransportIntegrationTests` does against the server
  /// it owns directly).
  func subscriberCountForTesting() async -> Int {
    guard let controlSocketServer else { return 0 }
    return await controlSocketServer.subscriberCount
  }
}
