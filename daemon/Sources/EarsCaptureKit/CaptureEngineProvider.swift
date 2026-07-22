import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Supplies the `AVAudioEngine` graph that ``MicCaptureBackend`` taps.
///
/// This is the seam that keeps the tap/ring/generation-counter/frame-count
/// pipeline **identical** whether the upstream node is the real microphone
/// (`AVAudioEngine().inputNode`, production) or an injected `AVAudioSourceNode`
/// that synthesises samples in its render block (tests). Because a synthetic
/// source node needs no capture permission, the exact same code path can be
/// exercised end-to-end against a real, running `AVAudioEngine` with zero TCC
/// involvement — no microphone prompt, no live-mic audio.
///
/// `makeCaptureEngine()` is called on the backend actor on first start and on
/// every route-change rebuild, so each call must return a *fresh*, fully
/// configured engine.
public protocol CaptureEngineProvider: Sendable {
  func makeCaptureEngine() throws -> CaptureEngine
}

/// One configured `AVAudioEngine` instance plus the node/bus/format to tap and
/// how to run it. Owned by the backend actor for the lifetime of one engine
/// generation; not `Sendable` (it wraps `AVAudioEngine`), and only ever touched
/// on the actor.
public final class CaptureEngine {
  /// How the engine produces audio.
  public enum Mode: Sendable {
    /// Real-time: `start()` begins hardware capture on the audio thread. The
    /// production microphone path.
    case realtime
    /// Manual offline rendering: `start()` arms the engine and callers pump it
    /// via ``render(frames:)``. Used by tests to drive a synthetic source node
    /// deterministically with no audio device and no permission.
    case offlineManual
  }

  public let engine: AVAudioEngine
  public let tapNode: AVAudioNode
  public let tapBus: AVAudioNodeBus
  public let tapFormat: AVAudioFormat
  public let mode: Mode

  /// `true` when this engine had its input bound to an explicit HAL device (not
  /// the system default). Binding provokes one *self-induced*
  /// `AVAudioEngineConfigurationChange` shortly after start; the backend uses
  /// this flag to know it must **suppress** that first change rather than
  /// rebuild on it — rebuilding mid-bind is the `AVAudioIOUnit` use-after-free
  /// that crashed the first attempt (see ``RealMicSourceProvider`` and commit
  /// `a2f01f9`). `false` for the system-default and synthetic paths, which
  /// induce no such change.
  public let boundInputDevice: Bool

  public init(
    engine: AVAudioEngine,
    tapNode: AVAudioNode,
    tapBus: AVAudioNodeBus,
    tapFormat: AVAudioFormat,
    mode: Mode,
    boundInputDevice: Bool = false
  ) {
    self.engine = engine
    self.tapNode = tapNode
    self.tapBus = tapBus
    self.tapFormat = tapFormat
    self.mode = mode
    self.boundInputDevice = boundInputDevice
  }

  /// Prepare and start the engine. Required before ``render(frames:)`` in
  /// manual mode; begins live capture in real-time mode.
  public func start() throws {
    engine.prepare()
    try engine.start()
  }

  /// Stop the engine.
  public func stop() {
    engine.stop()
  }

  /// Remove the installed tap. Call before ``stop()`` during teardown.
  public func removeTap() {
    tapNode.removeTap(onBus: tapBus)
  }

  /// Pump `frames` through the graph in manual offline mode, firing the tap.
  /// Precondition: `mode == .offlineManual`.
  @discardableResult
  public func render(frames: AVAudioFrameCount) throws -> AVAudioEngineManualRenderingStatus {
    precondition(mode == .offlineManual, "render(frames:) is only valid in manual offline mode")
    let output = engine.manualRenderingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames) else {
      throw CaptureEngineError.couldNotAllocateRenderBuffer
    }
    return try engine.renderOffline(frames, to: buffer)
  }
}

/// Errors from building or running a capture engine.
public enum CaptureEngineError: Error, Sendable {
  case couldNotAllocateRenderBuffer
}

/// The production ``CaptureEngineProvider``: taps the real microphone input node
/// of a fresh real-time `AVAudioEngine`.
///
/// **Input-device selection.** Rather than always following the system default
/// input, this binds the engine to a chosen device via ``InputDeviceSelection``:
/// an explicitly configured `deviceUID` when present, otherwise (by default) the
/// built-in mic. That default is what keeps a connected Bluetooth headset out of
/// the capture path — opening a Bluetooth input would force the whole device off
/// A2DP onto the hands-free profile and wreck its playback quality for as long as
/// `earsd` holds the mic open (see ``AudioInputDevice``). Selection is
/// best-effort: if no device matches, or binding fails, the engine falls back to
/// the system default input, exactly as before.
///
/// **Crash-safe binding.** The bind sets the HAL device on the input node's
/// audio unit (`kAudioOutputUnitProperty_CurrentDevice`) on a **fresh,
/// not-yet-started** engine, *before* the tap is installed and `start()` is
/// called — never on a live input node via `AUAudioUnit.setDeviceID`, which
/// crashed AVFoundation: the device/format change it induced fired
/// `AVAudioIOUnit`'s internal property listener, which raced the engine teardown
/// that ``MicCaptureBackend``'s route-change/stall rebuild performs and messaged
/// a freed engine (`EXC_BAD_ACCESS`; commit `a2f01f9`). Setting the device at
/// construction still provokes one self-induced `AVAudioEngineConfigurationChange`
/// once the engine starts, so ``makeCaptureEngine()`` flags the returned engine
/// (``CaptureEngine/boundInputDevice``) and ``MicCaptureBackend`` suppresses that
/// first change within a short settle window rather than rebuilding on it.
///
/// Constructing this and calling `makeCaptureEngine()` does **not** prompt for or
/// begin microphone capture — that happens only when the backend calls
/// ``CaptureEngine/start()`` on the returned engine, which is gated by a TCC grant
/// and is never done in automated tests. (Enumerating devices reads Core Audio
/// metadata only; it does not open an input or trigger a TCC prompt.)
public struct RealMicSourceProvider: CaptureEngineProvider {
  private let deviceUID: String
  private let preferBuiltIn: Bool
  private let enumerator: any AudioInputDeviceEnumerating
  private static let log = Logger(subsystem: "net.tomelliot.ears", category: "capture")

  /// - Parameters:
  ///   - deviceUID: A specific Core Audio device UID to bind to. Empty (the
  ///     default) means "no explicit device"; selection then falls to
  ///     `preferBuiltIn`.
  ///   - preferBuiltIn: When no `deviceUID` matches, prefer the built-in mic
  ///     over the system default input. Defaults to `true` so a connected
  ///     Bluetooth headset is never captured — and therefore never downgraded —
  ///     unless the user explicitly names it.
  ///   - enumerator: The device-enumeration seam; the real Core Audio one by
  ///     default, overridable in tests.
  public init(
    deviceUID: String = "",
    preferBuiltIn: Bool = true,
    enumerator: any AudioInputDeviceEnumerating = CoreAudioInputDeviceEnumerator()
  ) {
    self.deviceUID = deviceUID
    self.preferBuiltIn = preferBuiltIn
    self.enumerator = enumerator
  }

  public func makeCaptureEngine() throws -> CaptureEngine {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let boundInputDevice = bindInputDevice(on: input)
    // The bound device dictates the input node's output format, so read it
    // *after* binding; the tap must be installed at the device's real rate.
    let format = input.outputFormat(forBus: 0)
    return CaptureEngine(
      engine: engine, tapNode: input, tapBus: 0, tapFormat: format, mode: .realtime,
      boundInputDevice: boundInputDevice)
  }

  /// The input device this provider would bind, applying ``InputDeviceSelection``
  /// to the current device list — or `nil` to leave the engine on the system
  /// default. Pure (no `AVAudioEngine`, no live audio); the seam a fake
  /// enumerator drives to assert the built-in mic is preferred over Bluetooth.
  func resolvedInputDevice() -> AudioInputDevice? {
    InputDeviceSelection.choose(
      from: enumerator.inputDevices(),
      preferredUID: deviceUID,
      preferBuiltIn: preferBuiltIn)
  }

  /// Bind `input` to the resolved device (if any) **before** the engine starts
  /// and before any tap is installed — the crash-safe shape: set the HAL device
  /// on the not-yet-running unit via `kAudioOutputUnitProperty_CurrentDevice`,
  /// never override a live node with `AUAudioUnit.setDeviceID` (which crashed
  /// AVFoundation; see this type's doc comment and commit `a2f01f9`).
  ///
  /// Returns whether a device was actually bound, so the backend knows to expect
  /// — and suppress — the self-induced configuration change the bind provokes.
  /// Best-effort throughout: an absent selection, an inaccessible audio unit, or
  /// a failed HAL set all leave capture on the system default input rather than
  /// failing to start.
  private func bindInputDevice(on input: AVAudioInputNode) -> Bool {
    guard let chosen = resolvedInputDevice() else { return false }
    guard let unit = input.audioUnit else {
      Self.log.error(
        "mic capture could not access the input audio unit to bind device \(chosen.name, privacy: .public); using system default input"
      )
      return false
    }
    var deviceID: AudioDeviceID = chosen.id
    let status = AudioUnitSetProperty(
      unit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
      Self.log.error(
        "mic capture failed to bind input device \(chosen.name, privacy: .public) (uid \(chosen.uid, privacy: .public)): OSStatus \(status, privacy: .public); using system default input"
      )
      return false
    }
    Self.log.notice(
      "mic capture bound input device \(chosen.name, privacy: .public) (uid \(chosen.uid, privacy: .public)); a connected Bluetooth headset stays in A2DP"
    )
    return true
  }
}
