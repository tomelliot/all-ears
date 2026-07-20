import CoreAudio
import Foundation

/// How a ``ProcessTapEngine`` scopes its tap, per
/// `docs/specs/capture-daemon.md`'s "Audio capture (native APIs)":
/// the whole system (`system`), or a specific set of live processes
/// (`app:<bundle-id>`, resolved to PIDs upstream of this type).
public enum TapMode: Sendable, Hashable {
  case system
  case app(pids: [pid_t])
}

/// Errors from building or running a process-tap engine. Each names the
/// failing Core Audio call's `OSStatus` (or the offending pid), so a denial
/// or a genuine API failure surface with enough detail to act on.
public enum ProcessTapEngineError: Error, Sendable, Hashable, CustomStringConvertible {
  case tapCreationFailed(OSStatus)
  case aggregateDeviceCreationFailed(OSStatus)
  case formatQueryFailed(OSStatus)
  case ioProcCreationFailed(OSStatus)
  case deviceStartFailed(OSStatus)
  case pidTranslationFailed(pid_t)

  public var description: String {
    switch self {
    case .tapCreationFailed(let status):
      return "AudioHardwareCreateProcessTap failed (OSStatus \(status))"
    case .aggregateDeviceCreationFailed(let status):
      return "AudioHardwareCreateAggregateDevice failed (OSStatus \(status))"
    case .formatQueryFailed(let status):
      return "reading kAudioTapPropertyFormat failed (OSStatus \(status))"
    case .ioProcCreationFailed(let status):
      return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(status))"
    case .deviceStartFailed(let status):
      return "AudioDeviceStart failed (OSStatus \(status))"
    case .pidTranslationFailed(let pid):
      return "no AudioObjectID found for pid \(pid) (process not tappable, or already exited)"
    }
  }
}

/// One built process tap + its aggregate device (or, in tests, a fake
/// standing in for both): the resource this seam owns for the lifetime of
/// one engine generation, and the teardown that releases it.
///
/// Owned by the actor that built it; not `Sendable` (holds live Core Audio
/// object ids, or fake state, whose teardown must happen from one place) —
/// only ever touched from the actor that owns it, exactly like
/// `EarsCaptureKit.CaptureEngine` for mic. A protocol (not the concrete Core
/// Audio type directly) so ``SystemAudioCaptureBackend``'s ring/gate/
/// teardown/watchdog logic is unit-testable against a fake that never
/// touches real Core Audio — mirroring the mic backend's
/// `CaptureEngineProvider`/`CaptureEngine` split.
public protocol ProcessTapEngine: AnyObject {
  /// The tap's real format, read from `kAudioTapPropertyFormat` at creation
  /// time — never assumed (the FluidVoice/48kHz-stereo mistake the spec
  /// flags). A fake supplies whatever format its test wants to exercise.
  var format: AudioStreamBasicDescription { get }

  /// Installs `ioBlock` as the realtime IO callback and starts IO. The real
  /// conformance dispatches it directly on the IO thread (`nil` queue, per
  /// `AudioDeviceCreateIOProcIDWithBlock`'s own doc); a fake stores it so a
  /// test can invoke it directly with synthetic buffers.
  func start(ioBlock: @escaping @Sendable AudioDeviceIOBlock) throws

  /// Stops IO and releases the underlying resource(s). Idempotent.
  func stop()
}

/// The production ``ProcessTapEngine``: one real process tap + its private,
/// tap-only, no-sub-device aggregate device — the resources
/// `AudioHardwareCreateProcessTap`/`AudioHardwareCreateAggregateDevice`
/// allocate, per `docs/specs/capture-daemon.md`'s recipe, and the
/// teardown that releases them.
public final class RealProcessTapEngine: ProcessTapEngine {
  public let tapID: AudioObjectID
  public let aggregateDeviceID: AudioObjectID
  public let format: AudioStreamBasicDescription

  private var ioProcID: AudioDeviceIOProcID?
  private var isStopped = false

  init(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID, format: AudioStreamBasicDescription)
  {
    self.tapID = tapID
    self.aggregateDeviceID = aggregateDeviceID
    self.format = format
  }

  public func start(ioBlock: @escaping @Sendable AudioDeviceIOBlock) throws {
    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock)
    guard createStatus == noErr, let procID else {
      throw ProcessTapEngineError.ioProcCreationFailed(createStatus)
    }
    let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
    guard startStatus == noErr else {
      AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
      throw ProcessTapEngineError.deviceStartFailed(startStatus)
    }
    ioProcID = procID
  }

  /// Stops IO, destroys the IO proc, then destroys the aggregate device and
  /// the tap itself, in that order. Idempotent.
  public func stop() {
    guard !isStopped else { return }
    isStopped = true
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
      self.ioProcID = nil
    }
    AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
  }

  deinit {
    stop()
  }
}

/// Builds a ``ProcessTapEngine`` for a given ``TapMode``. This is the seam
/// that keeps ``SystemAudioCaptureBackend``'s ring/gate/teardown logic
/// testable with a fake, exactly as `EarsCaptureKit.CaptureEngineProvider`
/// does for mic — `RealProcessTapProvider` is the only conformance that
/// touches real Core Audio.
public protocol ProcessTapEngineProvider: Sendable {
  func makeTapEngine(mode: TapMode) throws -> any ProcessTapEngine
}

/// The production ``ProcessTapEngineProvider``: the full
/// `docs/specs/capture-daemon.md` recipe — `CATapDescription` →
/// `AudioHardwareCreateProcessTap` → a private, tap-only, no-sub-device
/// aggregate device via `AudioHardwareCreateAggregateDevice` → read the
/// real format from `kAudioTapPropertyFormat`.
public struct RealProcessTapProvider: ProcessTapEngineProvider {
  public init() {}

  public func makeTapEngine(mode: TapMode) throws -> any ProcessTapEngine {
    let description = try Self.makeDescription(for: mode)
    description.isPrivate = true

    var tapID: AudioObjectID = 0
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr else {
      throw ProcessTapEngineError.tapCreationFailed(tapStatus)
    }

    do {
      let format = try Self.readTapFormat(tapID)
      let aggregateDeviceID = try Self.makeAggregateDevice(wrapping: description)
      return RealProcessTapEngine(
        tapID: tapID, aggregateDeviceID: aggregateDeviceID, format: format)
    } catch {
      AudioHardwareDestroyProcessTap(tapID)
      throw error
    }
  }

  private static func makeDescription(for mode: TapMode) throws -> CATapDescription {
    switch mode {
    case .system:
      // A global tap of everything, mixed down to stereo -- no processes
      // excluded. This is the "system" source.
      return CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    case .app(let pids):
      let objectIDs = try pids.map(translateToProcessObject)
      return CATapDescription(stereoMixdownOfProcesses: objectIDs)
    }
  }

  /// `kAudioHardwarePropertyTranslatePIDToProcessObject`: the only way to
  /// turn a live process's PID into the `AudioObjectID` `CATapDescription`'s
  /// `processes` list needs.
  private static func translateToProcessObject(pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var qualifier = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), qualifierPointer, &dataSize, &objectID)
    }
    guard status == noErr, objectID != kAudioObjectUnknown else {
      throw ProcessTapEngineError.pidTranslationFailed(pid)
    }
    return objectID
  }

  /// `kAudioTapPropertyFormat`: the tap's real `AudioStreamBasicDescription`
  /// — read, never assumed.
  private static func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var format = AudioStreamBasicDescription()
    var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format)
    guard status == noErr else {
      throw ProcessTapEngineError.formatQueryFailed(status)
    }
    return format
  }

  /// A private, auto-start, tap-only aggregate device wrapping `description`
  /// — no `kAudioAggregateDeviceSubDeviceListKey` at all, per the spec's
  /// "tap-only aggregate with no sub-device, to avoid duplicate/echo audio".
  private static func makeAggregateDevice(wrapping description: CATapDescription) throws
    -> AudioObjectID
  {
    let tapUID = description.uuid.uuidString
    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "ears-tap-\(UUID().uuidString)",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: false,
        ]
      ],
    ]
    var aggregateDeviceID: AudioObjectID = 0
    let status = AudioHardwareCreateAggregateDevice(
      aggregateDescription as CFDictionary, &aggregateDeviceID)
    guard status == noErr else {
      throw ProcessTapEngineError.aggregateDeviceCreationFailed(status)
    }
    return aggregateDeviceID
  }
}
