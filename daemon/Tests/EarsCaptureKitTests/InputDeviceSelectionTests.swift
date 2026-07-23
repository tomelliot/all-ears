import CoreAudio
import Testing

@testable import EarsCaptureKit

@Suite("InputDeviceSelection")
struct InputDeviceSelectionTests {
  private func device(id: AudioObjectID, uid: String) -> AudioInputDevice {
    AudioInputDevice(id: id, uid: uid, name: uid)
  }

  private var builtIn: AudioInputDevice { device(id: 1, uid: "BuiltInMicrophoneDevice") }
  private var bluetooth: AudioInputDevice { device(id: 2, uid: "AirPods-Pro") }
  private var usb: AudioInputDevice { device(id: 3, uid: "USB-Mic") }

  @Test("an explicitly configured UID selects that device")
  func explicitUIDSelected() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth, usb], preferredUID: "USB-Mic")
    #expect(chosen == usb)
  }

  @Test("an explicit UID is honoured regardless of the device's transport (Bluetooth included)")
  func explicitBluetoothIsHonoured() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "AirPods-Pro")
    #expect(chosen == bluetooth)
  }

  @Test("with no configured UID, selection yields nil so the engine follows the system default")
  func noUIDYieldsSystemDefault() {
    let chosen = InputDeviceSelection.choose(from: [bluetooth, builtIn], preferredUID: "")
    #expect(chosen == nil)
  }

  @Test("a configured UID that is not present yields nil (system default), not a substitute device")
  func absentUIDYieldsSystemDefault() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "Not-Connected")
    #expect(chosen == nil)
  }

  @Test("whitespace-only UID is treated as unset")
  func whitespaceUIDIsUnset() {
    let chosen = InputDeviceSelection.choose(from: [builtIn, bluetooth], preferredUID: "   ")
    #expect(chosen == nil)
  }

  @Test("an empty device list yields nil")
  func emptyDeviceListYieldsNil() {
    let chosen = InputDeviceSelection.choose(from: [], preferredUID: "anything")
    #expect(chosen == nil)
  }
}
