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

  private func device(id: AudioObjectID, uid: String, transport: UInt32) -> AudioInputDevice {
    AudioInputDevice(id: id, uid: uid, name: uid, transportType: transport)
  }

  private var builtIn: AudioInputDevice {
    device(id: 1, uid: "BuiltInMicrophoneDevice", transport: kAudioDeviceTransportTypeBuiltIn)
  }
  private var bluetooth: AudioInputDevice {
    device(id: 2, uid: "AirPods-Pro", transport: kAudioDeviceTransportTypeBluetooth)
  }

  @Test("resolves the built-in mic over a connected Bluetooth headset")
  func prefersBuiltInOverBluetooth() {
    let provider = RealMicSourceProvider(enumerator: FakeEnumerator(devices: [bluetooth, builtIn]))
    #expect(provider.resolvedInputDevice() == builtIn)
  }

  @Test("an explicit device UID is honoured even when it is Bluetooth")
  func explicitBluetoothUIDHonoured() {
    let provider = RealMicSourceProvider(
      deviceUID: "AirPods-Pro", enumerator: FakeEnumerator(devices: [builtIn, bluetooth]))
    #expect(provider.resolvedInputDevice() == bluetooth)
  }

  @Test("with preferBuiltIn disabled and no explicit UID, resolves nil (system default)")
  func noPreferenceResolvesNil() {
    let provider = RealMicSourceProvider(
      preferBuiltIn: false, enumerator: FakeEnumerator(devices: [builtIn, bluetooth]))
    #expect(provider.resolvedInputDevice() == nil)
  }

  @Test("with only a Bluetooth input present and no explicit UID, resolves nil (system default)")
  func bluetoothOnlyResolvesNil() {
    let provider = RealMicSourceProvider(enumerator: FakeEnumerator(devices: [bluetooth]))
    #expect(provider.resolvedInputDevice() == nil)
  }
}
