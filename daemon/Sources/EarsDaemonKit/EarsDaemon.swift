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

  public init(
    sources: [SourceDescriptor],
    dataRoot: URL,
    socketPath: String,
    chunkSeconds: Double = 30,
    vad: EnergyVAD = EnergyVAD()
  ) {
    self.sources = sources
    self.dataRoot = dataRoot
    self.socketPath = socketPath
    self.chunkSeconds = chunkSeconds
    self.vad = vad
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

  private let captureActors: [SourceID: CaptureActor]
  /// The producer→subscriber bridge for live-feed events: every
  /// ``CaptureActor`` and the ``SessionRegistry`` publish into it from
  /// construction on, and ``start()`` attaches the socket server's fan-out
  /// once the listener is bound (see ``EventBus``'s lifetime rationale).
  private let eventBus: EventBus
  private var controlSocketServer: ControlSocketServer?
  private var controlServerRunTask: Task<Void, Never>?
  private var powerObserver: PowerObserver?

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
      let sourceDirectory = DataStoreLayout.sourceDirectory(
        dataRoot: configuration.dataRoot, sourceID: descriptor.id)
      try FileManager.default.createDirectory(
        at: sourceDirectory, withIntermediateDirectories: true)

      try Self.writeSourceMeta(descriptor, dataRoot: configuration.dataRoot)

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

      actors[descriptor.id] = CaptureActor(
        descriptor: descriptor,
        dataRoot: configuration.dataRoot,
        backend: backendFactory(descriptor),
        encoder: encoder,
        indexAppender: indexAppender,
        vad: configuration.vad,
        clock: clock,
        eventSink: eventSink)
    }
    self.captureActors = actors
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

    // Only now does a pub/sub consumer exist: route every event published by
    // the capture actors / session registry into the socket's fan-out. Events
    // published before this line (during source startup) were dropped by
    // design — no subscriber could have been connected yet anyway.
    await eventBus.attach { event in await socketServer.publish(event) }

    let observer = PowerObserver(captureActors: captureActors)
    await observer.startObserving()
    powerObserver = observer
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

    if let powerObserver {
      await powerObserver.stopObserving()
    }
    powerObserver = nil

    for actor in captureActors.values {
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
