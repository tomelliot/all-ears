import AVFoundation
import EarsCore
import os

/// Captures one microphone-class source into a stream of mono PCM
/// ``AudioBuffer``s, per the ``CaptureBackend`` seam.
///
/// Wires the realtime pieces together: a tap on the source node (real mic or an
/// injected synthetic node — see ``CaptureEngineProvider``) publishes buffers into
/// a lock-free ``AudioSampleRing``; a ``GenerationGate`` makes teardown safe
/// against in-flight callbacks; a consumer task drains the ring and yields
/// buffers; a debounced configuration-change handler rebuilds the engine on a
/// device-route change with ``ExponentialBackoff``; and a heartbeat-based stall
/// watchdog recovers a wedged engine. Frame counts come from the live buffer
/// layout (the FluidVoice guard, in ``AudioSampleRing/write(from:)``).
///
/// An `actor`: all engine mutation is serialised, and the realtime tap never hops
/// onto the actor — it captures only `Sendable` collaborators (ring, gate,
/// heartbeat, clock) and its install generation.
public actor MicCaptureBackend: CaptureBackend, CaptureStatsReporting {
  /// Tunables for the realtime hand-off and recovery machinery.
  public struct Config: Sendable {
    /// Ring capacity in samples. Default ~2 s at 48 kHz.
    public var ringCapacity: Int
    /// Consecutive drop-events before the ring fails the stream.
    public var maxConsecutiveDropEvents: Int
    /// How often the consumer drains the ring when it finds it empty.
    public var drainPollInterval: Duration
    /// Backoff schedule for route-change rebuild retries.
    public var backoff: ExponentialBackoff
    /// Coalescing window for a flurry of configuration-change notifications
    /// (Bluetooth route flaps), so a burst triggers one rebuild.
    public var routeChangeDebounce: Duration
    /// Whether the stall watchdog is armed (real-time engines only).
    public var enableStallWatchdog: Bool
    /// How often the watchdog checks for a stall.
    public var stallCheckInterval: Duration
    /// Silence, in seconds, between tap callbacks before the engine is judged
    /// wedged.
    public var stallThresholdSeconds: Double

    public init(
      ringCapacity: Int = 96_000,
      maxConsecutiveDropEvents: Int = AudioSampleRing.defaultMaxConsecutiveDropEvents,
      drainPollInterval: Duration = .milliseconds(5),
      backoff: ExponentialBackoff = ExponentialBackoff(),
      routeChangeDebounce: Duration = .milliseconds(500),
      enableStallWatchdog: Bool = true,
      stallCheckInterval: Duration = .seconds(2),
      stallThresholdSeconds: Double = 5
    ) {
      self.ringCapacity = ringCapacity
      self.maxConsecutiveDropEvents = maxConsecutiveDropEvents
      self.drainPollInterval = drainPollInterval
      self.backoff = backoff
      self.routeChangeDebounce = routeChangeDebounce
      self.enableStallWatchdog = enableStallWatchdog
      self.stallCheckInterval = stallCheckInterval
      self.stallThresholdSeconds = stallThresholdSeconds
    }
  }

  public nonisolated let source: SourceID

  private let provider: any CaptureEngineProvider
  private let clock: any NowProviding
  private let config: Config
  private let ring: AudioSampleRing
  private let gate = GenerationGate()
  private let heartbeat = HeartbeatMonitor()
  private nonisolated static let log = Logger(subsystem: "net.tomelliot.ears", category: "capture")

  private var engine: CaptureEngine?
  private var installGeneration: UInt64 = 0
  private var tapSampleRate = 48_000
  private var startedAt: Instant?

  private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var observerToken: (any NSObjectProtocol)?
  private var routeChangeEpoch = 0
  private var isRunning = false

  public init(
    source: SourceID = "mic",
    provider: any CaptureEngineProvider = RealMicSourceProvider(),
    clock: any NowProviding = SystemClock(),
    config: Config = Config()
  ) {
    self.source = source
    self.provider = provider
    self.clock = clock
    self.config = config
    ring = AudioSampleRing(
      capacity: config.ringCapacity,
      maxConsecutiveDropEvents: config.maxConsecutiveDropEvents)
  }

  public var stats: CaptureStats {
    CaptureStats(droppedSampleCount: ring.droppedSampleCount, hasFailed: ring.hasFailed)
  }

  public func start() async throws -> AsyncStream<CapturedAudioBuffer> {
    guard !isRunning else {
      throw CaptureBackendError.alreadyStarted
    }
    isRunning = true
    let (stream, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream()
    self.continuation = continuation

    do {
      try buildAndStartEngine()
    } catch {
      isRunning = false
      continuation.finish()
      self.continuation = nil
      throw error
    }

    startConsumerLoop()
    startWatchdogIfEnabled()
    return stream
  }

  public func stop() async {
    guard isRunning else { return }
    isRunning = false
    teardownCurrentEngine()
    consumerTask?.cancel()
    watchdogTask?.cancel()
    consumerTask = nil
    watchdogTask = nil
    continuation?.finish()
    continuation = nil
  }

  // MARK: - Engine lifecycle

  /// Build a fresh engine, install the tap under a fresh generation, and start.
  /// On failure removes the half-built tap and rethrows; `self.engine` stays nil.
  private func buildAndStartEngine() throws {
    let captureEngine = try provider.makeCaptureEngine()
    let generation = gate.generation  // freshly valid (teardown invalidated any prior)
    installTap(on: captureEngine, generation: generation)

    do {
      try captureEngine.start()
    } catch {
      captureEngine.removeTap()
      gate.invalidate()  // any callback that captured `generation` is now stale
      throw error
    }

    installGeneration = generation
    tapSampleRate = Int(captureEngine.tapFormat.sampleRate)
    startedAt = clock.now()
    heartbeat.reset()
    engine = captureEngine
    registerConfigurationChangeObserver(for: captureEngine)
  }

  private func installTap(on captureEngine: CaptureEngine, generation: UInt64) {
    let ring = self.ring
    let gate = self.gate
    let heartbeat = self.heartbeat
    let clock = self.clock
    captureEngine.tapNode.installTap(
      onBus: captureEngine.tapBus,
      bufferSize: 4096,
      format: captureEngine.tapFormat
    ) { buffer, _ in
      // Realtime thread. Drop stale callbacks from a torn-down engine first,
      // then stamp liveness and publish into the ring. Captures only Sendable
      // collaborators — never the actor.
      guard gate.isCurrent(generation) else { return }
      heartbeat.beat(clock.now())
      ring.write(from: buffer)
    }
  }

  /// Invalidate the generation *first* (so late callbacks are dropped), then
  /// remove the tap, stop the engine, and drop the observer. Idempotent.
  private func teardownCurrentEngine() {
    gate.invalidate()
    if let token = observerToken {
      NotificationCenter.default.removeObserver(token)
      observerToken = nil
    }
    if let captureEngine = engine {
      captureEngine.removeTap()
      captureEngine.stop()
      engine = nil
    }
  }

  // MARK: - Consumer

  private func startConsumerLoop() {
    consumerTask = Task { [weak self] in
      await self?.runConsumerLoop()
    }
  }

  private func runConsumerLoop() async {
    while isRunning && !Task.isCancelled {
      if ring.hasFailed {
        handleUnrecoverableFailure()
        return
      }
      let samples = ring.read(maxCount: config.ringCapacity)
      if samples.isEmpty {
        try? await Task.sleep(for: config.drainPollInterval)
      } else {
        continuation?.yield(CapturedAudioBuffer(samples: samples, sampleRate: tapSampleRate))
      }
    }
  }

  private func handleUnrecoverableFailure() {
    Self.log.error(
      "capture source \(self.source.rawValue, privacy: .public) failed: ring latched after \(self.ring.droppedSampleCount, privacy: .public) dropped samples under sustained backpressure"
    )
    isRunning = false
    teardownCurrentEngine()
    watchdogTask?.cancel()
    watchdogTask = nil
    continuation?.finish()
    continuation = nil
  }

  // MARK: - Route-change recovery

  private func registerConfigurationChangeObserver(for captureEngine: CaptureEngine) {
    observerToken = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: captureEngine.engine,
      queue: nil
    ) { [weak self] _ in
      Task { await self?.handleConfigurationChange() }
    }
  }

  /// Debounce a flurry of route-change notifications into a single rebuild.
  private func handleConfigurationChange() async {
    routeChangeEpoch += 1
    let epoch = routeChangeEpoch
    try? await Task.sleep(for: config.routeChangeDebounce)
    guard isRunning, epoch == routeChangeEpoch else { return }  // superseded or stopped
    Self.log.notice(
      "capture source \(self.source.rawValue, privacy: .public) rebuilding engine after device-route change"
    )
    await rebuildWithBackoff()
  }

  /// Tear down and rebuild the engine, retrying indefinitely with exponential
  /// backoff. Route flaps are transient (distinct from permission denial), so we
  /// never give up — we log a degraded state and keep trying.
  private func rebuildWithBackoff() async {
    var attempt = 0
    while isRunning && !Task.isCancelled {
      teardownCurrentEngine()
      do {
        try buildAndStartEngine()
        Self.log.notice(
          "capture source \(self.source.rawValue, privacy: .public) recovered after \(attempt, privacy: .public) failed rebuild attempt(s)"
        )
        return
      } catch {
        let delay = config.backoff.delay(forAttempt: attempt)
        Self.log.error(
          "capture source \(self.source.rawValue, privacy: .public) rebuild attempt \(attempt, privacy: .public) failed (degraded), retrying: \(error.localizedDescription, privacy: .public)"
        )
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  // MARK: - Stall watchdog

  private func startWatchdogIfEnabled() {
    guard config.enableStallWatchdog, engine?.mode == .realtime else { return }
    watchdogTask = Task { [weak self] in
      await self?.runWatchdogLoop()
    }
  }

  private func runWatchdogLoop() async {
    let detector = StallDetector(threshold: config.stallThresholdSeconds)
    while isRunning && !Task.isCancelled {
      try? await Task.sleep(for: config.stallCheckInterval)
      guard isRunning, !Task.isCancelled, let startedAt else { continue }
      if detector.isStalled(lastActivity: heartbeat.last, startedAt: startedAt, now: clock.now()) {
        Self.log.error(
          "capture source \(self.source.rawValue, privacy: .public) stalled (no tap callback within \(self.config.stallThresholdSeconds, privacy: .public)s); recovering"
        )
        await rebuildWithBackoff()
      }
    }
  }

  // MARK: - Testing hooks

  /// Pump `frames` through a manual-offline engine so tests drive a synthetic
  /// source node deterministically. Precondition: the current engine is in
  /// manual offline mode.
  @discardableResult
  func renderOfflineForTesting(frames: AVAudioFrameCount) throws
    -> AVAudioEngineManualRenderingStatus?
  {
    try engine?.render(frames: frames)
  }

  /// Simulate a device-route change synchronously (bypassing the debounce timer)
  /// so tests can assert rebuild behaviour without wall-clock waits.
  func simulateRouteChangeForTesting() async {
    await rebuildWithBackoff()
  }

  /// The generation a freshly-installed tap would have to match to be accepted.
  var currentInstallGeneration: UInt64 { installGeneration }

  /// Samples currently sitting in the ring, for teardown-safety assertions.
  var ringAvailableCountForTesting: Int { ring.availableCount }

  /// Drive one stale-callback attempt directly against the tap publish path,
  /// proving a callback holding `staleGeneration` is rejected after teardown.
  func attemptRingWriteForTesting(samples: [Float], generation: UInt64) {
    guard gate.isCurrent(generation) else { return }
    ring.write(samples)
  }

  /// Invalidate the current engine generation, as teardown does, without a full
  /// rebuild — for teardown-safety tests.
  func invalidateGenerationForTesting() {
    gate.invalidate()
  }
}

/// Errors surfaced by ``MicCaptureBackend``.
public enum CaptureBackendError: Error, Sendable {
  case alreadyStarted
}
