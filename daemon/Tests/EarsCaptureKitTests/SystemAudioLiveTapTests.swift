import Foundation
import Testing

@testable import EarsCaptureKit

/// Real, hardware-touching proof of concept for the Core Audio process-tap
/// recipe (``RealProcessTapProvider``, ``SystemAudioPermissionProvider``):
/// actually creates a global process tap and its private aggregate device
/// against this machine's real Core Audio HAL. Per the tier-2 rule in
/// `docs/engineering-practices.md`, this is deliberately **not** part of
/// the default `swift test` run — it touches real system state (a live
/// tap/aggregate device) and its result depends on this machine's current
/// System Audio Recording permission grant, neither of which belongs in a
/// gating CI suite. It only runs when `EARS_LIVE_SYSTEM_AUDIO_TEST=1` is
/// set.
///
/// This does not assert a specific ``PermissionStatus`` — that depends on
/// whatever this machine's grant currently is — it asserts that the real
/// recipe runs to completion (tap created, format read, aggregate device
/// built, IO started, torn down) without throwing, and prints the result
/// for a human to read.
@Suite(
  "SystemAudioCaptureBackend live tap (opt-in, real Core Audio)",
  .enabled(if: ProcessInfo.processInfo.environment["EARS_LIVE_SYSTEM_AUDIO_TEST"] == "1")
)
struct SystemAudioLiveTapTests {
  @Test("the real create-and-destroy TCC probe runs against a real global tap")
  func realProbeRuns() async {
    let provider = SystemAudioPermissionProvider()
    let status = await provider.status(for: .systemAudio)
    // Whatever this machine's grant currently is, the probe must resolve to
    // a real status (never silently crash or hang).
    print("real system-audio TCC probe resolved to: \(status)")
  }

  @Test("a real global tap can be built, read its live format, and torn down cleanly")
  func realTapBuildsAndTearsDown() throws {
    let provider = RealProcessTapProvider()
    let engine = try provider.makeTapEngine(mode: .system)
    print("real tap format: \(engine.format)")
    #expect(engine.format.mSampleRate > 0)
    #expect(engine.format.mChannelsPerFrame > 0)
    engine.stop()
  }
}
