import CoreAudio
import Testing

@testable import EarsCaptureKit

@Suite("InputDeviceSelection")
struct InputDeviceSelectionTests {
  private func device(
    id: AudioObjectID,
    uid: String,
    transport: UInt32
  ) -> AudioInputDevice {
    AudioInputDevice(id: id, uid: uid, name: uid, transportType: transport)
  }

  private var builtIn: AudioInputDevice {
    device(id: 1, uid: "BuiltInMicrophoneDevice", transport: kAudioDeviceTransportTypeBuiltIn)
  }
  private var bluetooth: AudioInputDevice {
    device(id: 2, uid: "AirPods-Pro", transport: kAudioDeviceTransportTypeBluetooth)
  }
  private var usb: AudioInputDevice {
    device(id: 3, uid: "USB-Mic", transport: kAudioDeviceTransportTypeUSB)
  }

  @Test("an explicitly configured UID wins, even over the built-in mic")
  func explicitUIDWins() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth, usb], preferredUID: "USB-Mic", preferBuiltIn: true)
    #expect(chosen == usb)
  }

  @Test("an explicit UID is honoured even when it is a Bluetooth device")
  func explicitBluetoothIsHonoured() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "AirPods-Pro", preferBuiltIn: true)
    #expect(chosen == bluetooth)
  }

  @Test("with no configured UID, the built-in mic is chosen over Bluetooth")
  func prefersBuiltInOverBluetooth() {
    let chosen = InputDeviceSelection.choose(
      from: [bluetooth, builtIn], preferredUID: "", preferBuiltIn: true)
    #expect(chosen == builtIn)
  }

  @Test("a configured UID that is not present falls back to the built-in mic")
  func absentUIDFallsBackToBuiltIn() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "Not-Connected", preferBuiltIn: true)
    #expect(chosen == builtIn)
  }

  @Test("with no built-in mic and no match, selection yields nil (system default)")
  func noBuiltInYieldsNil() {
    let chosen = InputDeviceSelection.choose(
      from: [bluetooth, usb], preferredUID: "", preferBuiltIn: true)
    #expect(chosen == nil)
  }

  @Test("preferBuiltIn=false with no configured UID yields nil (system default)")
  func preferBuiltInDisabledYieldsNil() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "", preferBuiltIn: false)
    #expect(chosen == nil)
  }

  @Test("whitespace-only UID is treated as unset")
  func whitespaceUIDIsUnset() {
    let chosen = InputDeviceSelection.choose(
      from: [builtIn, bluetooth], preferredUID: "   ", preferBuiltIn: true)
    #expect(chosen == builtIn)
  }

  @Test("an empty device list yields nil")
  func emptyDeviceListYieldsNil() {
    let chosen = InputDeviceSelection.choose(
      from: [], preferredUID: "anything", preferBuiltIn: true)
    #expect(chosen == nil)
  }

  @Test("transport-type classification flags Bluetooth LE and built-in correctly")
  func transportClassification() {
    let le = device(id: 4, uid: "LE", transport: kAudioDeviceTransportTypeBluetoothLE)
    #expect(le.isBluetooth)
    #expect(!le.isBuiltIn)
    #expect(builtIn.isBuiltIn)
    #expect(!builtIn.isBluetooth)
    #expect(!usb.isBluetooth)
  }
}
