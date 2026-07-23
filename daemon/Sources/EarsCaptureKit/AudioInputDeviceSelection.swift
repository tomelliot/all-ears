import AVFoundation
import CoreAudio

/// One microphone-class input device the system currently exposes, reduced to
/// just what ``InputDeviceSelection`` needs to match a configured `device_uid`:
/// its Core Audio object id (to bind an engine to), its stable UID (to match
/// the configured `device_uid`), and a human name (for logging).
public struct AudioInputDevice: Sendable, Equatable {
  public let id: AudioObjectID
  public let uid: String
  public let name: String

  public init(id: AudioObjectID, uid: String, name: String) {
    self.id = id
    self.uid = uid
    self.name = name
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
  /// Recording is meeting-scoped and brief, so there is no reason to steer away
  /// from any particular transport: the daemon simply follows whatever input
  /// the user has selected as the system default (Bluetooth included), unless
  /// they explicitly name a device.
  ///
  /// - A `preferredUID` that is currently present binds that device.
  /// - Anything else (no `preferredUID`, or one that isn't connected) returns
  ///   `nil`: the engine follows the system default input.
  public static func choose(
    from devices: [AudioInputDevice],
    preferredUID: String
  ) -> AudioInputDevice? {
    let trimmed = preferredUID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return devices.first(where: { $0.uid == trimmed })
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
/// channel, and reads each one's UID and name. Every Core Audio failure
/// degrades to "skip this device" / "return what we have" rather than throwing
/// — device selection is a best-effort optimisation over the default input,
/// never a hard requirement for capture to start.
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
        name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
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
