import AVFoundation
import CoreAudio

/// One microphone-class input device the system currently exposes, reduced to
/// just what ``InputDeviceSelection`` needs to choose between them: its Core
/// Audio object id (to bind an engine to), its stable UID (to match a
/// configured `device_uid`), a human name (for logging), and its transport
/// type (to tell a built-in mic from a Bluetooth headset).
///
/// **Why transport type matters here.** A Bluetooth headset cannot run
/// high-quality A2DP output *and* offer a mic input at the same time — the
/// profiles are mutually exclusive. The moment any process opens the headset's
/// input, macOS forces the whole device onto the hands-free profile (mono,
/// 8–16 kHz, in both directions) and its playback collapses to call quality.
/// Because `earsd` holds the mic open continuously, capturing a Bluetooth
/// input would pin the user's headphones in that degraded profile for as long
/// as they are connected. Preferring the built-in mic (`docs/specs/capture-daemon.md`'s
/// "Mic / device") sidesteps this entirely: the far end of any call is already
/// captured losslessly by the system/app process tap, and the built-in mic
/// hears the local speaker perfectly well while they wear headphones.
public struct AudioInputDevice: Sendable, Equatable {
  public let id: AudioObjectID
  public let uid: String
  public let name: String
  public let transportType: UInt32

  public init(id: AudioObjectID, uid: String, name: String, transportType: UInt32) {
    self.id = id
    self.uid = uid
    self.name = name
    self.transportType = transportType
  }

  /// The Mac's own microphone (or line input), never a Bluetooth device.
  public var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

  /// A Bluetooth headset/earbud — the transport whose input forces the A2DP →
  /// hands-free downgrade this whole seam exists to avoid.
  public var isBluetooth: Bool {
    transportType == kAudioDeviceTransportTypeBluetooth
      || transportType == kAudioDeviceTransportTypeBluetoothLE
  }
}

/// Chooses which input device the mic source should bind to, as pure logic over
/// a snapshot of the available devices — the enumeration (real Core Audio) is a
/// separate seam (``AudioInputDeviceEnumerating``) so this policy is unit-testable
/// with fabricated devices and no audio hardware.
public enum InputDeviceSelection {
  /// Resolve the device to bind, or `nil` to leave the engine on the system
  /// default input.
  ///
  /// Order of preference:
  /// 1. An explicitly configured `preferredUID` that is currently present —
  ///    the user named a device, so honour it even if it is Bluetooth.
  /// 2. Otherwise, when `preferBuiltIn`, the built-in mic — avoiding the
  ///    Bluetooth A2DP downgrade (see ``AudioInputDevice``).
  /// 3. Otherwise `nil` — no override; the engine follows the system default
  ///    input (the historical behaviour, and the only option on a Mac with no
  ///    built-in mic and no configured device).
  public static func choose(
    from devices: [AudioInputDevice],
    preferredUID: String,
    preferBuiltIn: Bool
  ) -> AudioInputDevice? {
    let trimmed = preferredUID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, let match = devices.first(where: { $0.uid == trimmed }) {
      return match
    }
    if preferBuiltIn, let builtIn = devices.first(where: { $0.isBuiltIn }) {
      return builtIn
    }
    return nil
  }
}

/// The seam that supplies the current input devices to ``InputDeviceSelection``.
/// `Sendable` so a provider can hold one; the real conformance is the only code
/// here that touches Core Audio.
public protocol AudioInputDeviceEnumerating: Sendable {
  func inputDevices() -> [AudioInputDevice]
}

/// The production ``AudioInputDeviceEnumerating``: walks
/// `kAudioHardwarePropertyDevices`, keeps those with at least one input
/// channel, and reads each one's UID, name, and transport type. Every Core
/// Audio failure degrades to "skip this device" / "return what we have" rather
/// than throwing — device selection is a best-effort optimisation over the
/// default input, never a hard requirement for capture to start.
public struct CoreAudioInputDeviceEnumerator: AudioInputDeviceEnumerating {
  public init() {}

  public func inputDevices() -> [AudioInputDevice] {
    allDeviceIDs().compactMap { id in
      guard deviceHasInput(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
        return nil
      }
      return AudioInputDevice(
        id: id,
        uid: uid,
        name: stringProperty(id, kAudioObjectPropertyName) ?? uid,
        transportType: transportType(id))
    }
  }

  private func allDeviceIDs() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
      return []
    }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids) == noErr
    else {
      return []
    }
    return ids
  }

  /// `true` if `id` exposes at least one input channel — the filter that keeps
  /// pure-output devices (speakers, the aggregate tap devices this daemon
  /// creates elsewhere) out of the mic candidate set.
  private func deviceHasInput(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0
    else {
      return false
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw) == noErr else {
      return false
    }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.contains { $0.mNumberChannels > 0 }
  }

  private func transportType(_ id: AudioObjectID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var transport: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &transport) == noErr else {
      return kAudioDeviceTransportTypeUnknown
    }
    return transport
  }

  private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
    }
    guard status == noErr else { return nil }
    return value as String?
  }
}
