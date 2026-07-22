import CoreAudio
import Testing

@testable import EarsCaptureKit

/// Covers ``RealMicSourceProvider``'s device-*resolution* seam
/// (``RealMicSourceProvider/resolvedInputDevice()``) driven by a fake
/// enumerator — the pure enumerate → ``InputDeviceSelection`` policy wiring,
/// with no `AVAudioEngine`, no live audio, and no real Core Audio device
/// binding. The actual HAL bind is exercised only on real hardware (see
/// `docs/specs/capture-daemon.md`'s verification plan).
@Suite("RealMicSourceProvider device resolution")
struct RealMicSourceProviderTests {
  /// A fabricated device list, so the resolution policy runs against known
  /// devices instead of whatever hardware the test host happens to expose.
  private struct FakeEnumerator: AudioInputDeviceEnumerating {
    let devices: [AudioInputDevice]
    func inputDevices() -> [AudioInputDevice] { devices }
  }

  private func device(id: AudioObjectID, uid: String) -> AudioInputDevice {
    AudioInputDevice(id: id, uid: uid, name: uid)
  }

  private var builtIn: AudioInputDevice { device(id: 1, uid: "BuiltInMicrophoneDevice") }
  private var bluetooth: AudioInputDevice { device(id: 2, uid: "AirPods-Pro") }

  @Test("with no explicit device UID, resolves nil so capture follows the system default input")
  func noUIDResolvesSystemDefault() {
    let provider = RealMicSourceProvider(enumerator: FakeEnumerator(devices: [bluetooth, builtIn]))
    #expect(provider.resolvedInputDevice() == nil)
  }

  @Test("an explicit device UID is honoured, even when it is a Bluetooth device")
  func explicitBluetoothUIDHonoured() {
    let provider = RealMicSourceProvider(
      deviceUID: "AirPods-Pro", enumerator: FakeEnumerator(devices: [builtIn, bluetooth]))
    #expect(provider.resolvedInputDevice() == bluetooth)
  }

  @Test("an explicit device UID that is not present resolves nil (system default)")
  func absentUIDResolvesSystemDefault() {
    let provider = RealMicSourceProvider(
      deviceUID: "Not-Connected", enumerator: FakeEnumerator(devices: [builtIn, bluetooth]))
    #expect(provider.resolvedInputDevice() == nil)
  }
}
