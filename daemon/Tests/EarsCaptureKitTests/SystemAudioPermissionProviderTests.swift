import CoreAudio
import EarsCore
import Testing

@testable import EarsCaptureKit

@Suite("SystemAudioPermissionProvider")
struct SystemAudioPermissionProviderTests {
  private static func monoFloatASBD() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0)
  }

  @Test("an all-zero probe window maps to .denied")
  func allZeroMapsToDenied() async {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0, 0, 0, 0])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.status(for: .systemAudio)
    #expect(status == .denied)
    #expect(engine.stopCallCountForTesting == 1)
  }

  @Test("a real (non-zero) probe window maps to .authorized")
  func nonZeroMapsToAuthorized() async {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.1, 0.2, 0.3])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.status(for: .systemAudio)
    #expect(status == .authorized)
    #expect(engine.stopCallCountForTesting == 1)
  }

  @Test("no samples at all maps to .notDetermined, not a denial guess")
  func noSamplesMapsToNotDetermined() async {
    let engine = FakeProcessTapEngine(format: Self.monoFloatASBD())
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.status(for: .systemAudio)
    #expect(status == .notDetermined)
  }

  @Test("a tap-build failure maps to .notDetermined")
  func buildFailureMapsToNotDetermined() async {
    let provider = FakeProcessTapEngineProvider(makeEngine: {
      FakeProcessTapEngine(format: Self.monoFloatASBD())
    })
    provider.buildError = ProcessTapEngineError.tapCreationFailed(-1)
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.status(for: .systemAudio)
    #expect(status == .notDetermined)
  }

  @Test("a tap-start failure maps to .notDetermined")
  func startFailureMapsToNotDetermined() async {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), startError: ProcessTapEngineError.deviceStartFailed(-1))
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.status(for: .systemAudio)
    #expect(status == .notDetermined)
  }

  @Test(".microphone always resolves to .notDetermined (MicrophonePermissionProvider's concern)")
  func microphoneIsNotDetermined() async {
    let provider = FakeProcessTapEngineProvider(makeEngine: {
      FakeProcessTapEngine(format: Self.monoFloatASBD())
    })
    let permissions = SystemAudioPermissionProvider(tapProvider: provider)

    let status = await permissions.status(for: .microphone)
    #expect(status == .notDetermined)
  }

  @Test("request(_:) probes the same way status(for:) does")
  func requestProbesLikeStatus() async {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.5])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    let status = await permissions.request(.systemAudio)
    #expect(status == .authorized)
  }

  @Test("the probe tap is a global (.system) tap")
  func probesWithSystemMode() async {
    let engine = FakeProcessTapEngine(
      format: Self.monoFloatASBD(), autoFireSamplesOnStart: [0.1])
    let provider = FakeProcessTapEngineProvider(makeEngine: { engine })
    let permissions = SystemAudioPermissionProvider(
      tapProvider: provider, probeWindow: .milliseconds(5))

    _ = await permissions.status(for: .systemAudio)
    #expect(provider.requestedModesForTesting == [.system])
  }
}
