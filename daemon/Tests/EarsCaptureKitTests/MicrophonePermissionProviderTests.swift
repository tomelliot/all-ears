import AVFoundation
import EarsCore
import Synchronization
import Testing

@testable import EarsCaptureKit

@Suite("MicrophonePermissionProvider")
struct MicrophonePermissionProviderTests {
  @Test(
    "maps each AVAuthorizationStatus to the matching PermissionStatus",
    arguments: [
      (AVAuthorizationStatus.authorized, PermissionStatus.authorized),
      (.denied, .denied),
      (.notDetermined, .notDetermined),
      (.restricted, .restricted),
    ])
  func mapsStatus(platform: AVAuthorizationStatus, expected: PermissionStatus) async {
    let provider = MicrophonePermissionProvider(statusSource: { _ in platform })
    let status = await provider.status(for: .microphone)
    #expect(status == expected)
  }

  @Test("systemAudio is not this provider's concern")
  func systemAudioNotDetermined() async {
    let provider = MicrophonePermissionProvider(statusSource: { _ in .authorized })
    #expect(await provider.status(for: .systemAudio) == .notDetermined)
  }

  @Test("status queries the microphone media type")
  func queriesAudioMediaType() async {
    let seen = MediaTypeRecorder()
    let provider = MicrophonePermissionProvider(statusSource: { type in
      seen.record(type)
      return .authorized
    })
    _ = await provider.status(for: .microphone)
    #expect(seen.value == .audio)
  }

  @Test("request maps a granted access to authorized (no real prompt)")
  func requestGranted() async {
    // The access requester is faked: no AVCaptureDevice.requestAccess call, so
    // no system prompt and no TCC involvement.
    let provider = MicrophonePermissionProvider(
      statusSource: { _ in .notDetermined },
      accessRequester: { _ in true })
    #expect(await provider.request(.microphone) == .authorized)
  }

  @Test("request maps a refused access to denied (no real prompt)")
  func requestDenied() async {
    let provider = MicrophonePermissionProvider(
      statusSource: { _ in .notDetermined },
      accessRequester: { _ in false })
    #expect(await provider.request(.microphone) == .denied)
  }
}

/// Captures the media type a status query asked about, for assertion.
private final class MediaTypeRecorder: Sendable {
  private let stored = Mutex<AVMediaType?>(nil)
  func record(_ type: AVMediaType) {
    stored.withLock { $0 = type }
  }
  var value: AVMediaType? {
    stored.withLock { $0 }
  }
}
