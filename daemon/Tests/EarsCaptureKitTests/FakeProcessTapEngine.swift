import CoreAudio
import Synchronization

@testable import EarsCaptureKit

/// A test-only ``ProcessTapEngine``/``ProcessTapEngineProvider`` pair that
/// never touches real Core Audio — the tier-2 "test the protocol with a
/// mock" half of `docs/engineering-practices.md`'s rule for hardware shims.
///
/// `@unchecked Sendable`, mirroring ``AudioSampleRing``'s own justified
/// exception: the real `AudioDeviceIOBlock` a production tap installs is
/// designed to be invoked from an arbitrary realtime thread, so this fake's
/// `fireIOBlock` is deliberately called from a test's own task, not through
/// the owning actor. The closure field is `nonisolated(unsafe)` (it is
/// written once, on the actor, during `start(ioBlock:)`, then read later
/// from the test's task — safe in practice because `await backend.start()`
/// returning is itself a happens-before edge, which the compiler's static
/// isolation check cannot see); every other mutable field goes through a
/// `Mutex`. This is test-only infrastructure, not shipped production code,
/// so it does not widen the codebase's single production exception
/// (`AudioSampleRing`).
final class FakeProcessTapEngine: ProcessTapEngine, @unchecked Sendable {
  let format: AudioStreamBasicDescription
  var startError: (any Error)?
  /// When set, `start(ioBlock:)` fires the block once, synchronously, with
  /// these samples immediately after storing it — deterministically
  /// depositing data into the backend's ring before it ever reaches its
  /// grace-window sleep, with no timing race against a concurrent test
  /// task. `nil` (the default) fires nothing automatically.
  var autoFireSamplesOnStart: [Float]?
  nonisolated(unsafe) private var ioBlock: AudioDeviceIOBlock?
  private let stopCallCount = Mutex(0)

  init(
    format: AudioStreamBasicDescription, startError: (any Error)? = nil,
    autoFireSamplesOnStart: [Float]? = nil
  ) {
    self.format = format
    self.startError = startError
    self.autoFireSamplesOnStart = autoFireSamplesOnStart
  }

  func start(ioBlock: @escaping AudioDeviceIOBlock) throws {
    if let startError { throw startError }
    self.ioBlock = ioBlock
    if let autoFireSamplesOnStart {
      fireIOBlock(samples: autoFireSamplesOnStart)
    }
  }

  func stop() {
    stopCallCount.withLock { $0 += 1 }
  }

  var stopCallCountForTesting: Int {
    stopCallCount.withLock { $0 }
  }

  /// Builds a real `AudioBufferList` from `samples` and invokes the
  /// installed IO block directly, exactly as a real tap's realtime callback
  /// would — the seam every `SystemAudioCaptureBackend` behavior test drives
  /// through.
  func fireIOBlock(samples: [Float], channelCount: Int = 1) {
    guard let ioBlock else { return }

    let abl = AudioBufferList.allocate(maximumBuffers: 1)
    defer { abl.unsafeMutablePointer.deallocate() }

    samples.withUnsafeBufferPointer { pointer in
      abl[0] = AudioBuffer(
        mNumberChannels: UInt32(channelCount),
        mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(mutating: pointer.baseAddress))

      var now = AudioTimeStamp()
      var inputTime = AudioTimeStamp()
      let outputList = AudioBufferList.allocate(maximumBuffers: 1)
      defer { outputList.unsafeMutablePointer.deallocate() }
      ioBlock(&now, abl.unsafePointer, &inputTime, outputList.unsafeMutablePointer, &inputTime)
    }
  }
}

/// A ``ProcessTapEngineProvider`` returning pre-configured
/// ``FakeProcessTapEngine``s (or throwing a configured error), recording
/// every requested ``TapMode`` — the fake half of the seam
/// ``RealProcessTapProvider`` is the real half of.
final class FakeProcessTapEngineProvider: ProcessTapEngineProvider, @unchecked Sendable {
  private struct State {
    var requestedModes: [TapMode] = []
  }

  private let state = Mutex(State())
  nonisolated(unsafe) private var lastEngine: FakeProcessTapEngine?
  private let makeEngine: @Sendable () -> FakeProcessTapEngine
  var buildError: (any Error)?

  init(makeEngine: @escaping @Sendable () -> FakeProcessTapEngine) {
    self.makeEngine = makeEngine
  }

  func makeTapEngine(mode: TapMode) throws -> any ProcessTapEngine {
    state.withLock { $0.requestedModes.append(mode) }
    if let buildError { throw buildError }
    let engine = makeEngine()
    lastEngine = engine
    return engine
  }

  var requestedModesForTesting: [TapMode] {
    state.withLock { $0.requestedModes }
  }

  var lastEngineForTesting: FakeProcessTapEngine? {
    lastEngine
  }
}

/// A controllable ``RunningApplicationTracking`` for `.app`-mode rebuild
/// tests: `livePIDs` is whatever the test last set, and `events()` replays
/// whatever the test feeds via ``sendForTesting(_:)`` — never real
/// `NSWorkspace` notifications.
final class FakeRunningApplicationTracker: RunningApplicationTracking, @unchecked Sendable {
  private struct State {
    var pids: [String: [pid_t]] = [:]
  }

  private let state = Mutex(State())
  nonisolated(unsafe) private var continuation: AsyncStream<RunningApplicationEvent>.Continuation?

  func setLivePIDs(_ pids: [pid_t], forBundleID bundleID: String) {
    state.withLock { $0.pids[bundleID] = pids }
  }

  func livePIDs(forBundleID bundleID: String) -> [pid_t] {
    state.withLock { $0.pids[bundleID] ?? [] }
  }

  func events() -> AsyncStream<RunningApplicationEvent> {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }

  func sendForTesting(_ event: RunningApplicationEvent) {
    continuation?.yield(event)
  }
}
