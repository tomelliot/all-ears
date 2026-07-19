import CoreAudio
import EarsCore
import Testing

@testable import EarsCaptureKit

@Suite("SystemAudioCaptureBackend")
struct SystemAudioCaptureBackendTests {
  private static func monoFloatASBD(sampleRate: Double = 48_000) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0)
  }

  private func testConfig(
    deniedGraceWindow: Duration = .milliseconds(10),
    appRebuildDebounce: Duration = .milliseconds(10),
    enableStallWatchdog: Bool = false,
    stallCheckInterval: Duration = .milliseconds(10),
    stallThresholdSeconds: Double = 0.05
  ) -> SystemAudioCaptureBackend.Config {
    SystemAudioCaptureBackend.Config(
      drainPollInterval: .milliseconds(1),
      appRebuildDebounce: appRebuildDebounce,
      enableStallWatchdog: enableStallWatchdog,
      stallCheckInterval: stallCheckInterval,
      stallThresholdSeconds: stallThresholdSeconds,
      deniedGraceWindow: deniedGraceWindow)
  }

  @Test("real (non-zero) audio during the grace window flows through the stream")
  func realAudioFlowsThroughStream() async throws {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.5, 0.5, 0.5])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    let stream = try await backend.start()
    var collected: [Float] = []
    for await buffer in stream {
      #expect(buffer.sampleRate == 48_000)
      collected.append(contentsOf: buffer.samples)
      if collected.count >= 3 { break }
    }
    await backend.stop()

    #expect(collected == [0.5, 0.5, 0.5])
    #expect(provider.requestedModesForTesting == [.system])
  }

  @Test("an all-zero grace window throws permissionDenied and tears the engine down")
  func allZeroGraceWindowIsPermissionDenied() async throws {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0, 0, 0, 0])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    await #expect(throws: SystemAudioCaptureError.self) {
      _ = try await backend.start()
    }
    #expect(engine.stopCallCountForTesting == 1)
  }

  @Test("no samples at all during the grace window is not treated as denial")
  func noSamplesIsNotDenial() async throws {
    // No autoFireSamplesOnStart -- nothing arrives during the grace window,
    // which is a stall/wedge concern, not a permission one.
    let engine = FakeProcessTapEngine(format: Self.monoFloatASBD())
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    let stream = try await backend.start()
    await backend.stop()
    _ = stream
  }

  @Test("a build failure surfaces as engineBuildFailed")
  func buildFailureSurfaces() async {
    let provider = FakeProcessTapEngineProvider(makeEngine: {
      FakeProcessTapEngine(format: Self.monoFloatASBD())
    })
    provider.buildError = ProcessTapEngineError.tapCreationFailed(-1)
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    await #expect(throws: SystemAudioCaptureError.self) {
      _ = try await backend.start()
    }
  }

  @Test("starting twice throws alreadyStarted")
  func startingTwiceThrows() async throws {
    let engine = FakeProcessTapEngine(format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.1])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    _ = try await backend.start()
    await #expect(throws: CaptureBackendError.alreadyStarted) {
      _ = try await backend.start()
    }
    await backend.stop()
  }

  @Test("stats surface a clean stream after normal capture")
  func statsCleanAfterCapture() async throws {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.5, 0.5])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let backend = SystemAudioCaptureBackend(
      source: "system", mode: .system, provider: provider, config: testConfig())

    let stream = try await backend.start()
    var collected = 0
    for await buffer in stream {
      collected += buffer.samples.count
      if collected >= 2 { break }
    }
    let stats = await backend.stats
    await backend.stop()

    #expect(collected >= 2)
    #expect(!stats.hasFailed)
  }

  @Test(".app mode requests a tap scoped to the given PIDs")
  func appModeRequestsScopedPIDs() async throws {
    let engine = FakeProcessTapEngine(format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.2])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let tracker = FakeRunningApplicationTracker()
    tracker.setLivePIDs([111, 222], forBundleID: "us.zoom.xos")

    let backend = SystemAudioCaptureBackend(
      source: "app:us.zoom.xos", mode: .app(pids: [111, 222]), bundleID: "us.zoom.xos",
      provider: provider, tracker: tracker, config: testConfig())

    _ = try await backend.start()
    await backend.stop()

    #expect(provider.requestedModesForTesting == [.app(pids: [111, 222])])
  }

  @Test(".app mode rebuilds the tap when the tracked bundle id's live PID set changes")
  func appModeRebuildsOnProcessSetChange() async throws {
    let provider = FakeProcessTapEngineProvider(makeEngine: {
      FakeProcessTapEngine(format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.3])
    })
    let tracker = FakeRunningApplicationTracker()
    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")

    let backend = SystemAudioCaptureBackend(
      source: "app:us.zoom.xos", mode: .app(pids: [111]), bundleID: "us.zoom.xos",
      provider: provider, tracker: tracker, config: testConfig())

    _ = try await backend.start()
    #expect(provider.requestedModesForTesting == [.app(pids: [111])])

    // The app-events consumer Task is spawned but not necessarily scheduled
    // yet; give it a moment to actually start iterating `tracker.events()`
    // (and so register its continuation) before sending an event, or the
    // event is dropped with no subscriber to receive it.
    try await Task.sleep(for: .milliseconds(20))

    // A second process joins the tracked bundle id.
    tracker.setLivePIDs([111, 333], forBundleID: "us.zoom.xos")
    tracker.sendForTesting(.launched(bundleID: "us.zoom.xos", pid: 333))

    // Debounce (10ms in testConfig) then the rebuild itself need a moment.
    try await Task.sleep(for: .milliseconds(200))
    await backend.stop()

    #expect(provider.requestedModesForTesting.contains(.app(pids: [111, 333])))
  }

  @Test(".app mode ignores events for a different bundle id")
  func appModeIgnoresUnrelatedBundleID() async throws {
    let provider = FakeProcessTapEngineProvider(makeEngine: {
      FakeProcessTapEngine(format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.3])
    })
    let tracker = FakeRunningApplicationTracker()
    tracker.setLivePIDs([111], forBundleID: "us.zoom.xos")

    let backend = SystemAudioCaptureBackend(
      source: "app:us.zoom.xos", mode: .app(pids: [111]), bundleID: "us.zoom.xos",
      provider: provider, tracker: tracker, config: testConfig())

    _ = try await backend.start()
    tracker.sendForTesting(.launched(bundleID: "com.other.app", pid: 999))
    try await Task.sleep(for: .milliseconds(100))
    await backend.stop()

    #expect(provider.requestedModesForTesting == [.app(pids: [111])])
  }
}
