import CoreAudio
import EarsCore
import os

// CoreAudio's C `AudioBuffer` struct and EarsCore's `AudioBuffer` model
// collide by name once both modules are imported; this scoped import makes
// the bare identifier below resolve to EarsCore's unambiguously.
import struct EarsCore.AudioBuffer

/// Errors surfaced by ``SystemAudioCaptureBackend``.
public enum SystemAudioCaptureError: Error, Sendable, CustomStringConvertible {
  /// The tap's first grace window of audio was all-zero — the signature of
  /// a TCC-denied system-audio tap (`docs/specs/capture-daemon.md`'s
  /// "Permissions and TCC probing": no query API exists, so this is
  /// detected by observing the stream itself).
  case permissionDenied
  case engineBuildFailed(any Error)

  public var description: String {
    switch self {
    case .permissionDenied:
      return
        "System audio recording permission is not granted. Open System Settings > Privacy & "
        + "Security > Screen & System Audio Recording > System Audio Recording Only, and enable "
        + "it for this app (macOS 15's \"System Audio Recording Only\" sub-pane)."
    case .engineBuildFailed(let error):
      return "failed to build the system-audio tap: \(error)"
    }
  }
}

/// Captures the `system` or `app:<bundle-id>` source class into a stream of
/// mono PCM ``AudioBuffer``s, per the ``CaptureBackend`` seam — the Core
/// Audio process-tap counterpart to ``MicCaptureBackend``.
///
/// Structurally mirrors ``MicCaptureBackend`` (``AudioSampleRing``/
/// ``GenerationGate``/``HeartbeatMonitor``/``StallDetector``/
/// ``ExponentialBackoff`` reused verbatim — none of that machinery is
/// mic-specific), but the engine underneath is a raw Core Audio HAL
/// aggregate device (``ProcessTapEngine``) rather than an `AVAudioEngine`:
/// the realtime hand-off is an `AudioDeviceIOBlock`, not a tap-node
/// callback.
///
/// **In-process by design, stall watchdog non-negotiable.** Per
/// `docs/specs/capture-daemon.md`'s "Isolation option for the
/// riskiest syscalls": the process tap is the most crash-prone surface in
/// the whole capture path, and an external-process (`audiotee`-style)
/// isolation boundary is an explicitly deferred hardening option — not
/// built here. Kept in-process for simplicity, which is exactly why the
/// stall watchdog is mandatory rather than optional (a wedged in-process tap
/// otherwise never surfaces as an error).
///
/// **Per-app scoping is the least-proven path** (the spec's own words): a
/// `.app` mode backend tracks its target bundle id's live PIDs and rebuilds
/// the tap's inclusion list as they come and go (``RunningApplicationTracking``),
/// but whether the tap's `processes` list *actually* isolates that app's
/// audio from everything else is only proven by the dedicated, opt-in
/// integration test — never assumed from this type alone.
public actor SystemAudioCaptureBackend: CaptureBackend, CaptureStatsReporting {
  public struct Config: Sendable {
    public var ringCapacity: Int
    public var maxConsecutiveDropEvents: Int
    public var drainPollInterval: Duration
    public var backoff: ExponentialBackoff
    /// Coalescing window for a flurry of process launch/exit notifications
    /// for the tracked bundle id (`.app` mode only), so a burst of Chrome
    /// helper processes starting/stopping triggers one tap rebuild.
    public var appRebuildDebounce: Duration
    public var enableStallWatchdog: Bool
    public var stallCheckInterval: Duration
    public var stallThresholdSeconds: Double
    /// How long ``start()`` waits after starting real IO before deciding
    /// whether the stream looks TCC-denied (see ``AllZeroPCMDetector``'s
    /// documented limitation: this is a heuristic, not a query).
    public var deniedGraceWindow: Duration

    public init(
      ringCapacity: Int = 96_000,
      maxConsecutiveDropEvents: Int = AudioSampleRing.defaultMaxConsecutiveDropEvents,
      drainPollInterval: Duration = .milliseconds(5),
      backoff: ExponentialBackoff = ExponentialBackoff(),
      appRebuildDebounce: Duration = .milliseconds(500),
      enableStallWatchdog: Bool = true,
      stallCheckInterval: Duration = .seconds(2),
      stallThresholdSeconds: Double = 5,
      deniedGraceWindow: Duration = .milliseconds(500)
    ) {
      self.ringCapacity = ringCapacity
      self.maxConsecutiveDropEvents = maxConsecutiveDropEvents
      self.drainPollInterval = drainPollInterval
      self.backoff = backoff
      self.appRebuildDebounce = appRebuildDebounce
      self.enableStallWatchdog = enableStallWatchdog
      self.stallCheckInterval = stallCheckInterval
      self.stallThresholdSeconds = stallThresholdSeconds
      self.deniedGraceWindow = deniedGraceWindow
    }
  }

  public nonisolated let source: SourceID

  private let mode: TapMode
  private let bundleID: String?
  private let provider: any ProcessTapEngineProvider
  private let tracker: any RunningApplicationTracking
  private let clock: any NowProviding
  private let config: Config
  private let ring: AudioSampleRing
  private let gate = GenerationGate()
  private let heartbeat = HeartbeatMonitor()
  private nonisolated static let log = Logger(subsystem: "net.tomelliot.ears", category: "capture")

  private var engine: (any ProcessTapEngine)?
  private var tapSampleRate = 48_000
  private var startedAt: Instant?
  private var currentPIDs: [pid_t] = []

  private var continuation: AsyncStream<AudioBuffer>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var appEventsTask: Task<Void, Never>?
  private var rebuildEpoch = 0
  private var isRunning = false

  /// - Parameters:
  ///   - source: `"system"` or `"app:<bundle-id>"`.
  ///   - mode: `.system` for a global tap, `.app(pids:)` for a per-process
  ///     tap scoped to `bundleID`'s live processes at construction time (kept
  ///     current afterward via `tracker`'s launch/terminate events).
  ///   - bundleID: The bundle id to track for `.app` mode's PID-set rebuild;
  ///     `nil` for `.system` (nothing to track).
  public init(
    source: SourceID,
    mode: TapMode,
    bundleID: String? = nil,
    provider: any ProcessTapEngineProvider = RealProcessTapProvider(),
    tracker: any RunningApplicationTracking = RealRunningApplicationTracker(),
    clock: any NowProviding = SystemClock(),
    config: Config = Config()
  ) {
    self.source = source
    self.mode = mode
    self.bundleID = bundleID
    self.provider = provider
    self.tracker = tracker
    self.clock = clock
    self.config = config
    ring = AudioSampleRing(
      capacity: config.ringCapacity, maxConsecutiveDropEvents: config.maxConsecutiveDropEvents)
    if case .app(let pids) = mode {
      currentPIDs = pids
    }
  }

  public var stats: CaptureStats {
    CaptureStats(droppedSampleCount: ring.droppedSampleCount, hasFailed: ring.hasFailed)
  }

  public func start() async throws -> AsyncStream<AudioBuffer> {
    guard !isRunning else { throw CaptureBackendError.alreadyStarted }
    isRunning = true
    let (stream, continuation) = AsyncStream<AudioBuffer>.makeStream()
    self.continuation = continuation

    do {
      try buildAndStartEngine()
    } catch {
      isRunning = false
      continuation.finish()
      self.continuation = nil
      throw SystemAudioCaptureError.engineBuildFailed(error)
    }

    // Grace-window TCC-denial check, *before* the normal consumer loop
    // starts — any real samples collected during the wait are still
    // delivered below, not discarded.
    try? await Task.sleep(for: config.deniedGraceWindow)
    let sampled = ring.read(maxCount: config.ringCapacity)
    if !sampled.isEmpty && AllZeroPCMDetector.isAllZero(sampled) {
      teardownCurrentEngine()
      isRunning = false
      continuation.finish()
      self.continuation = nil
      Self.log.error(
        "capture source \(self.source.rawValue, privacy: .public) looks TCC-denied (all-zero PCM during grace window)"
      )
      throw SystemAudioCaptureError.permissionDenied
    }
    if !sampled.isEmpty {
      continuation.yield(AudioBuffer(samples: sampled, sampleRate: tapSampleRate))
    }

    startConsumerLoop()
    startWatchdogIfEnabled()
    if case .app = mode {
      startAppEventObserving()
    }
    return stream
  }

  public func stop() async {
    guard isRunning else { return }
    isRunning = false
    teardownCurrentEngine()
    consumerTask?.cancel()
    watchdogTask?.cancel()
    appEventsTask?.cancel()
    consumerTask = nil
    watchdogTask = nil
    appEventsTask = nil
    continuation?.finish()
    continuation = nil
  }

  // MARK: - Engine lifecycle

  private func buildAndStartEngine() throws {
    let tapMode: TapMode = {
      switch mode {
      case .system: return .system
      case .app: return .app(pids: currentPIDs)
      }
    }()
    let tapEngine = try provider.makeTapEngine(mode: tapMode)
    let generation = gate.generation

    let asbd = tapEngine.format
    let channelCount = Int(asbd.mChannelsPerFrame)
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let bytesPerChannelSample = Int(asbd.mBitsPerChannel) / 8
    let ring = self.ring
    let gateRef = self.gate
    let heartbeatRef = self.heartbeat
    let clockRef = self.clock

    do {
      try tapEngine.start { _, inputData, _, _, _ in
        guard gateRef.isCurrent(generation) else { return }
        heartbeatRef.beat(clockRef.now())
        guard bytesPerChannelSample > 0 else { return }
        let bytesInFirstBuffer = Int(inputData.pointee.mBuffers.mDataByteSize)
        let perBufferChannels = nonInterleaved ? 1 : max(channelCount, 1)
        let frames = bytesInFirstBuffer / bytesPerChannelSample / perBufferChannels
        guard frames > 0 else { return }
        ring.write(from: inputData, frameCount: frames, asbd: asbd)
      }
    } catch {
      tapEngine.stop()
      gate.invalidate()
      throw error
    }

    engine = tapEngine
    tapSampleRate = Int(asbd.mSampleRate)
    startedAt = clock.now()
    heartbeat.reset()
  }

  private func teardownCurrentEngine() {
    gate.invalidate()
    engine?.stop()
    engine = nil
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
        continuation?.yield(AudioBuffer(samples: samples, sampleRate: tapSampleRate))
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
    appEventsTask?.cancel()
    appEventsTask = nil
    continuation?.finish()
    continuation = nil
  }

  // MARK: - Per-app PID-set rebuild

  /// Subscribes to `tracker.events()` *synchronously*, before spawning the
  /// consumer task — `events()`'s side effect (registering the real
  /// `NSWorkspace` observer, or a fake's continuation) must happen before
  /// this method returns, not whenever the spawned `Task` eventually gets
  /// scheduled, or a launch/terminate landing in that gap would be silently
  /// missed.
  private func startAppEventObserving() {
    guard let bundleID else { return }
    let events = tracker.events()
    appEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .launched(let eventBundleID, _), .terminated(let eventBundleID, _):
          guard eventBundleID == bundleID else { continue }
          await self.handleAppEvent()
        }
      }
    }
  }

  private func handleAppEvent() async {
    guard let bundleID else { return }
    rebuildEpoch += 1
    let epoch = rebuildEpoch
    try? await Task.sleep(for: config.appRebuildDebounce)
    guard isRunning, epoch == rebuildEpoch else { return }

    let newPIDs = tracker.livePIDs(forBundleID: bundleID).sorted()
    guard newPIDs != currentPIDs.sorted() else { return }
    currentPIDs = newPIDs
    Self.log.notice(
      "capture source \(self.source.rawValue, privacy: .public) rebuilding tap: process set changed"
    )
    await rebuildWithBackoff()
  }

  /// Tear down and rebuild the engine, retrying indefinitely with
  /// exponential backoff — matching ``MicCaptureBackend``'s route-change
  /// recovery: a process-set change or transient tap failure is retried
  /// forever rather than giving up (distinct from a permission denial,
  /// which is a hard, immediate failure at ``start()``).
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
    guard config.enableStallWatchdog else { return }
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

  /// The live PID set the current (or next-built) tap uses, for `.app` mode
  /// rebuild tests.
  var currentPIDsForTesting: [pid_t] { currentPIDs }
}
