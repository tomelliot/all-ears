/// Core Audio / `AVAudioEngine` capture shim: adapts the microphone to
/// `EarsCore`'s `CaptureBackend` protocol seam, per `docs/architecture.md`'s
/// module structure.
///
/// The capture pipeline lives in ``MicCaptureBackend`` (tap + ``AudioSampleRing``
/// + ``GenerationGate`` + route-change recovery + stall watchdog) and
/// ``MicrophonePermissionProvider``. This namespace retains the module version.
public enum EarsCaptureKit {
  /// Version of the `EarsCaptureKit` module.
  public static let version = "0.1.0"
}
