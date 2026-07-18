import EarsCore
import EarsDataStore
import EarsIPC
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
  /// `[earsd.ingest_ws]`, or `nil` when disabled (the default) — gates
  /// whether ``EarsDaemon/start()`` also binds the loopback ingest
  /// WebSocket.
  public var ingestWebSocket: IngestWebSocketConfiguration?

  public init(
    sources: [SourceDescriptor],
    dataRoot: URL,
    socketPath: String,
    chunkSeconds: Double = 30,
    vad: EnergyVAD = EnergyVAD(),
    codec: String = "aac",
    bitrate: Int = 64_000,
    defaultTimeCapSeconds: Int = 7_200,
    ingestWebSocket: IngestWebSocketConfiguration? = nil
  ) {
    self.sources = sources
    self.dataRoot = dataRoot
    self.socketPath = socketPath
    self.chunkSeconds = chunkSeconds
    self.vad = vad
    self.codec = codec
    self.bitrate = bitrate
    self.defaultTimeCapSeconds = defaultTimeCapSeconds
    self.ingestWebSocket = ingestWebSocket
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
  private let log: @Sendable (String) -> Void

  private var captureActors: [SourceID: CaptureActor]
  /// The producer→subscriber bridge for live-feed events: every
  /// ``CaptureActor`` and the ``SessionRegistry`` publish into it from
  /// construction on, and ``start()`` attaches the socket server's fan-out
  /// once the listener is bound (see ``EventBus``'s lifetime rationale).
  private let eventBus: EventBus
  private var controlSocketServer: ControlSocketServer?
  private var controlServerRunTask: Task<Void, Never>?
  private var controlServer: ControlServer?
  private var powerObserver: PowerObserver?

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

  /// Builds every source's `CaptureActor` (and its `ChunkEncoder`/
  /// `IndexAppender`) from `configuration`, but starts nothing yet — no
  /// backend is started, no socket is bound, until ``start()``.
  ///
  /// - Throws: if a source's on-disk directory can't be created, or its
  ///   `ChunkEncoder` can't be constructed (an invalid native/ASR sample-rate
  ///   pairing) — both indicate a fundamentally broken configuration, so
  ///   construction fails outright rather than degrading one source, unlike
  ///   ``start()``'s per-source backend-failure isolation.
  public init(
    configuration: EarsDaemonConfiguration,
    backendFactory: @escaping CaptureBackendFactory,
    clock: any NowProviding = SystemClock(),
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) throws {
    self.configuration = configuration
    self.clock = clock
    self.log = log

    let eventBus = EventBus()
    self.eventBus = eventBus
    let eventSink: EventSink = { event in await eventBus.publish(event) }

    var actors: [SourceID: CaptureActor] = [:]
    for descriptor in configuration.sources {
      actors[descriptor.id] = try Self.buildCaptureActor(
        for: descriptor,
        configuration: configuration,
        backend: backendFactory(descriptor),
        clock: clock,
        eventSink: eventSink)
    }
    self.captureActors = actors
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
    eventSink: EventSink?
  ) throws -> CaptureActor {
    let sourceDirectory = DataStoreLayout.sourceDirectory(
      dataRoot: configuration.dataRoot, sourceID: descriptor.id)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)

    try writeSourceMeta(descriptor, dataRoot: configuration.dataRoot)

    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.indexFile(
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
      vad: configuration.vad,
      clock: clock,
      eventSink: eventSink)
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
    for (id, actor) in captureActors.sorted(by: { $0.key < $1.key }) {
      do {
        try await actor.start()
      } catch {
        log("source '\(id.rawValue)' failed to start and is disabled: \(error)")
      }
    }

    let sessions = SessionRegistry(
      dataRoot: configuration.dataRoot,
      knownSourceIDs: { [captureActors] in Set(captureActors.keys) },
      clock: clock,
      eventSink: { [eventBus] event in await eventBus.publish(event) })
    let controlServer = ControlServer(
      captureActors: captureActors,
      sessions: sessions,
      dataRoot: configuration.dataRoot,
      startInstant: clock.now(),
      clock: clock)

    let socketDirectory = URL(fileURLWithPath: configuration.socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: socketDirectory, withIntermediateDirectories: true)

    let listener = try await NetworkSocketListener.bind(toPath: configuration.socketPath)
    let socketServer = ControlSocketServer(
      listener: listener, log: log, handler: controlServer.makeHandler())
    controlSocketServer = socketServer
    controlServerRunTask = Task { await socketServer.run() }
    // Kept so openIngestSource(label:format:) can register a dynamically-
    // created source into this SAME actor's captureActors — otherwise it's
    // a value-type copy neither sees the other's later changes to.
    self.controlServer = controlServer

    // Only now does a pub/sub consumer exist: route every event published by
    // the capture actors / session registry into the socket's fan-out. Events
    // published before this line (during source startup) were dropped by
    // design — no subscriber could have been connected yet anyway.
    await eventBus.attach { event in await socketServer.publish(event) }

    let observer = PowerObserver(captureActors: captureActors)
    await observer.startObserving()
    powerObserver = observer

    if let ingestWebSocket = configuration.ingestWebSocket {
      await startIngestWebSocket(ingestWebSocket)
    }
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
      onOpen: { [weak self] label, format in
        guard let self else { throw IngestError.notABrowserSource(label) }
        return try await self.openIngestSource(label: label, format: format)
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

    if let ingestWebSocketServer {
      await ingestWebSocketServer.shutdown()
    }
    ingestServerRunTask?.cancel()
    ingestServerRunTask = nil
    self.ingestWebSocketServer = nil

    if let powerObserver {
      await powerObserver.stopObserving()
    }
    powerObserver = nil

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
  /// Known gap: `SessionRegistry.knownSourceIDs` and `PowerObserver` were
  /// each handed a snapshot of `captureActors` at `start()`, so a session
  /// can't reference a browser source opened after start, and the power
  /// observer won't pause/resume it on sleep/wake. Only `ControlServer`'s
  /// copy is kept in sync (via `registerDynamicSource`), since `status`/
  /// `sources.list` visibility is this task's actual exit bar; the other two
  /// are a follow-up, not silently assumed fixed.
  public func openIngestSource(label: SourceID, format: AudioFormatSpec) async throws -> String {
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
        eventSink: { [eventBus] event in await eventBus.publish(event) })
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
