import AVFoundation
import EarsCore
import Testing

@testable import EarsCaptureKit

/// Tier-2 integration coverage: a real `AVAudioEngine` driven by a synthetic
/// source node through the production tap/ring/generation pipeline. No TCC grant,
/// no live-mic audio, no audio device (offline rendering).
@Suite("MicCaptureBackend")
struct MicCaptureBackendTests {
  private func testConfig() -> MicCaptureBackend.Config {
    MicCaptureBackend.Config(
      drainPollInterval: .milliseconds(1),
      enableStallWatchdog: false)
  }

  @Test("real audio flows end-to-end through the tap, ring, and stream", .timeLimit(.minutes(1)))
  func audioFlowsEndToEnd() async throws {
    let provider = SyntheticSourceNodeProvider(sampleValue: 0.5)
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    let stream = try await backend.start()

    // Pump frames through the real engine's manual renderer. We render more than
    // we assert on: the mixer/output graph carries a small latency tail, so the
    // last render pulls flush earlier samples out through the tap.
    let framesPerChunk: AVAudioFrameCount = 512
    let renderedChunks = 24
    for _ in 0..<renderedChunks {
      let status = try await backend.renderOfflineForTesting(frames: framesPerChunk)
      #expect(status == .success)
    }
    // Assert on a target comfortably below what's produced: the graph/tap
    // latency withholds a tail, so exact-count fidelity is left to the ring's
    // unit tests; here we prove a substantial stream of correct samples flows.
    let target = 12 * Int(framesPerChunk)

    var collected: [Float] = []
    for await buffer in stream {
      #expect(buffer.sampleRate == 48_000)
      collected.append(contentsOf: buffer.samples)
      if collected.count >= target { break }
    }
    await backend.stop()

    #expect(collected.count >= target)  // real samples flowed through the pipeline
    #expect(collected.allSatisfy { $0 == 0.5 })  // exactly what the source synthesised
    #expect(provider.totalFramesProduced == renderedChunks * Int(framesPerChunk))
  }

  @Test("stats surface a clean stream after normal capture", .timeLimit(.minutes(1)))
  func statsCleanAfterCapture() async throws {
    let provider = SyntheticSourceNodeProvider()
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    let stream = try await backend.start()
    for _ in 0..<12 { try await backend.renderOfflineForTesting(frames: 512) }

    var collected = 0
    for await buffer in stream {
      collected += buffer.samples.count
      if collected >= 2048 { break }
    }
    let stats = await backend.stats
    await backend.stop()

    #expect(collected >= 2048)
    #expect(stats.droppedSampleCount == 0)
    #expect(!stats.hasFailed)
  }

  @Test("a stale callback is rejected after teardown increments the generation")
  func staleCallbackRejectedThroughBackend() async throws {
    let provider = SyntheticSourceNodeProvider()
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    _ = try await backend.start()

    let installedGeneration = await backend.currentInstallGeneration
    let before = await backend.ringAvailableCountForTesting

    // Teardown increments the generation, as engine stop/rebuild does.
    await backend.invalidateGenerationForTesting()

    // A callback from the old engine instance, holding the pre-teardown
    // generation, must be dropped rather than corrupting the ring.
    await backend.attemptRingWriteForTesting(
      samples: [0.1, 0.2, 0.3], generation: installedGeneration)
    let after = await backend.ringAvailableCountForTesting
    #expect(after == before)  // stale write dropped

    await backend.stop()
  }

  @Test("start twice throws alreadyStarted", .timeLimit(.minutes(1)))
  func doubleStartThrows() async throws {
    let provider = SyntheticSourceNodeProvider()
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    _ = try await backend.start()
    await #expect(throws: CaptureBackendError.alreadyStarted) {
      _ = try await backend.start()
    }
    await backend.stop()
  }

  @Test("rebuild after a simulated route change resumes capture", .timeLimit(.minutes(1)))
  func rebuildResumesCapture() async throws {
    let provider = SyntheticSourceNodeProvider()
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    let stream = try await backend.start()

    // Force a rebuild (fresh engine generation), as a device-route change would.
    await backend.simulateRouteChangeForTesting()

    // Capture still works after the rebuild.
    for _ in 0..<12 { try await backend.renderOfflineForTesting(frames: 512) }
    var collected = 0
    for await buffer in stream {
      collected += buffer.samples.count
      if collected >= 2048 { break }
    }
    await backend.stop()
    #expect(collected >= 2048)
  }

  @Test(
    "buffers are restamped with the new device rate after a route change",
    .timeLimit(.minutes(1)))
  func restampsSampleRateAfterRouteChange() async throws {
    let provider = SyntheticSourceNodeProvider()
    let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
    let stream = try await backend.start()

    // Before the change: buffers carry the initial 48 kHz stamp.
    for _ in 0..<12 { try await backend.renderOfflineForTesting(frames: 512) }
    var sawInitialRate = false
    for await buffer in stream {
      #expect(buffer.sampleRate == 48_000)
      sawInitialRate = true
      break
    }
    #expect(sawInitialRate)

    // The input device switches to 16 kHz; a route change rebuilds the engine,
    // and the backend re-reads the new tap rate.
    provider.setSampleRate(16_000)
    await backend.simulateRouteChangeForTesting()

    for _ in 0..<12 { try await backend.renderOfflineForTesting(frames: 512) }
    var sawNewRate = false
    for await buffer in stream {
      // Skip any buffers still queued from the pre-change 48 kHz generation.
      if buffer.sampleRate == 48_000 { continue }
      #expect(buffer.sampleRate == 16_000)
      sawNewRate = true
      break
    }
    await backend.stop()
    #expect(sawNewRate)  // the load-bearing input to normalization: restamped on rebuild
  }
}
