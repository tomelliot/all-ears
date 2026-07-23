import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// A controllable ``RunningApplicationTracking`` fake -- never real
/// `NSWorkspace` notifications, per this task's injection requirement.
private final class FakeTracker: RunningApplicationTracking, @unchecked Sendable {
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

  func send(_ event: RunningApplicationEvent) {
    continuation?.yield(event)
  }
}

/// Records every `(name, arguments)` pair a scripted ``AppSignalTriggerObserver
/// .ProcessRunner`` fake was called with, and lets a test script each call's
/// exit code (and, optionally, the stderr it "captured").
private final class FakeProcessRunner: @unchecked Sendable {
  private struct State {
    var calls: [(name: String, arguments: [String])] = []
    var exitCodes: [Int32] = []
    var stderr: String = ""
  }
  private let state = Mutex(State())

  init(exitCodes: [Int32], stderr: String = "") {
    state.withLock {
      $0.exitCodes = exitCodes
      $0.stderr = stderr
    }
  }

  var runner: AppSignalTriggerObserver.ProcessRunner {
    { name, arguments in
      self.state.withLock { s in
        s.calls.append((name, arguments))
        let exitCode = s.exitCodes.isEmpty ? 0 : s.exitCodes.removeFirst()
        return SpawnOutcome(exitCode: exitCode, stderr: exitCode == 0 ? "" : s.stderr)
      }
    }
  }

  var callsForTesting: [(name: String, arguments: [String])] {
    state.withLock { $0.calls }
  }
}

@Suite("AppSignalTriggerObserver")
struct AppSignalTriggerObserverTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppSignalTriggerObserverTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRegistry(dataRoot: URL, clock: ManualClock) -> SessionRegistry {
    SessionRegistry(
      dataRoot: dataRoot,
      knownSourceIDs: { ["mic", "app:us.zoom.xos"] },
      clock: clock)
  }

  private static let meetingsRule = TriggerRuleConfiguration(
    name: "meetings",
    on: "app-audio-active",
    apps: ["us.zoom.xos"],
    openSession: true,
    sources: ["mic", "app:us.zoom.xos"],
    onClose: ["transcribe", "cleanup", "summarize"])

  @Test("a launch followed by genuine audio activity opens a session with the rule's sources")
  func launchThenAudioActiveOpensSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let tracker = FakeTracker()
    let runner = FakeProcessRunner(exitCodes: [])

    let observer = AppSignalTriggerObserver(
      rules: [Self.meetingsRule], sessions: registry, outputRoot: dataRoot, tracker: tracker,
      runProcess: runner.runner)
    await observer.start()
    try await Task.sleep(for: .milliseconds(20))  // let the subscriber actually start

    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")
    tracker.send(.launched(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(20))

    // Launch alone must not open a session -- only genuine audio activity.
    var sessions = await registry.list()
    #expect(sessions.isEmpty)

    await observer.handle(.vad(source: "app:us.zoom.xos", state: .speech, t: clock.now()))
    try await Task.sleep(for: .milliseconds(20))

    sessions = await registry.list()
    #expect(sessions.count == 1)
    #expect(sessions.first?.sources == ["mic", "app:us.zoom.xos"])
    #expect(sessions.first?.trigger == .appSignal)
    #expect(sessions.first?.state == .open)
  }

  @Test("a vad-speech signal on an unrelated app is ignored")
  func vadOnUnrelatedAppIsIgnored() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let tracker = FakeTracker()

    let observer = AppSignalTriggerObserver(
      rules: [Self.meetingsRule], sessions: registry, outputRoot: dataRoot, tracker: tracker,
      runProcess: { _, _ in SpawnOutcome(exitCode: 0) })
    await observer.start()

    await observer.handle(.vad(source: "app:com.other.app", state: .speech, t: clock.now()))
    try await Task.sleep(for: .milliseconds(10))
    #expect(await registry.list().isEmpty)
  }

  @Test("the matched app's last process exiting closes the session and runs on_close in order")
  func lastProcessExitingClosesAndRunsPipeline() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let tracker = FakeTracker()
    let runner = FakeProcessRunner(exitCodes: [])

    let observer = AppSignalTriggerObserver(
      rules: [Self.meetingsRule], sessions: registry, outputRoot: dataRoot, tracker: tracker,
      runProcess: runner.runner)
    await observer.start()
    try await Task.sleep(for: .milliseconds(20))

    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")
    tracker.send(.launched(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(20))
    await observer.handle(.vad(source: "app:us.zoom.xos", state: .speech, t: clock.now()))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await registry.list().count == 1)
    let sessionID = try #require(await registry.list().first?.id)

    // Last process exits.
    tracker.setLivePIDs([], forBundleID: "us.zoom.xos")
    tracker.send(.terminated(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(30))

    let closed = await registry.list().first
    #expect(closed?.state == .closed)

    let calls = runner.callsForTesting
    #expect(calls.map(\.name) == ["transcribe", "cleanup", "summarize"])
    #expect(calls[0].arguments == ["--session", sessionID])
    #expect(calls[1].arguments.count == 1)
    #expect(calls[1].arguments[0].hasSuffix(".transcript.md"))
    #expect(calls[2].arguments[0].hasSuffix(".clean.md"))
    #expect(calls[2].arguments[1] == "--all-presets")
  }

  @Test("a failed on_close stage stops the chain rather than silently continuing")
  func failedStageStopsChain() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let tracker = FakeTracker()
    // transcribe succeeds, cleanup fails -> summarize must never run.
    let runner = FakeProcessRunner(exitCodes: [0, 1])

    let observer = AppSignalTriggerObserver(
      rules: [Self.meetingsRule], sessions: registry, outputRoot: dataRoot, tracker: tracker,
      runProcess: runner.runner)
    await observer.start()
    try await Task.sleep(for: .milliseconds(20))

    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")
    tracker.send(.launched(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(20))
    await observer.handle(.vad(source: "app:us.zoom.xos", state: .speech, t: clock.now()))
    try await Task.sleep(for: .milliseconds(20))

    tracker.setLivePIDs([], forBundleID: "us.zoom.xos")
    tracker.send(.terminated(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(30))

    let calls = runner.callsForTesting
    #expect(calls.map(\.name) == ["transcribe", "cleanup"])
  }

  @Test("a second audio-active signal while a session is already open does not open another")
  func secondAudioActiveDoesNotReopen() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let tracker = FakeTracker()

    let observer = AppSignalTriggerObserver(
      rules: [Self.meetingsRule], sessions: registry, outputRoot: dataRoot, tracker: tracker,
      runProcess: { _, _ in SpawnOutcome(exitCode: 0) })
    await observer.start()

    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")
    tracker.send(.launched(bundleID: "us.zoom.xos", pid: 111))
    try await Task.sleep(for: .milliseconds(20))
    await observer.handle(.vad(source: "app:us.zoom.xos", state: .speech, t: clock.now()))
    await observer.handle(.vad(source: "app:us.zoom.xos", state: .speech, t: clock.now()))
    try await Task.sleep(for: .milliseconds(20))

    #expect(await registry.list().count == 1)
  }
}
