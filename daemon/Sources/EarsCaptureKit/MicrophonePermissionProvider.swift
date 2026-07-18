import AVFoundation
import EarsCore

extension PermissionStatus {
  /// Map a platform `AVAuthorizationStatus` to the suite's ``PermissionStatus``,
  /// keeping AVFoundation types out of pure code. An unknown future case is
  /// treated as ``denied`` — the safe default (never assume a grant).
  init(authorizationStatus: AVAuthorizationStatus) {
    switch authorizationStatus {
    case .authorized: self = .authorized
    case .denied: self = .denied
    case .notDetermined: self = .notDetermined
    case .restricted: self = .restricted
    @unknown default: self = .denied
    }
  }
}

/// A ``PermissionProviding`` for the microphone grant, backed by
/// `AVCaptureDevice`.
///
/// Per `docs/specs/capture-daemon.md`'s "Permissions and TCC probing", the mic
/// grant *is* queryable (unlike the system-audio tap): ``status(for:)`` reads
/// `AVCaptureDevice.authorizationStatus(for: .audio)` — a side-effect-free query
/// that never prompts. ``request(_:)`` calls
/// `AVCaptureDevice.requestAccess(for: .audio)`, which shows the system prompt
/// and must be triggered only from a real user-facing flow — never in automated
/// tests. A missing grant disables just this source, never the daemon.
///
/// Both the status read and the access request are injected so the mapping logic
/// is unit-testable without touching TCC: tests pass fakes and never invoke the
/// real prompt. This provider covers `microphone`; the system-audio tap probe is
/// a separate later task, so `systemAudio` resolves to ``notDetermined`` here.
public struct MicrophonePermissionProvider: PermissionProviding {
  private let statusSource: @Sendable (AVMediaType) -> AVAuthorizationStatus
  private let accessRequester: @Sendable (AVMediaType) async -> Bool

  public init(
    statusSource: @escaping @Sendable (AVMediaType) -> AVAuthorizationStatus = {
      AVCaptureDevice.authorizationStatus(for: $0)
    },
    accessRequester: @escaping @Sendable (AVMediaType) async -> Bool = {
      await AVCaptureDevice.requestAccess(for: $0)
    }
  ) {
    self.statusSource = statusSource
    self.accessRequester = accessRequester
  }

  public func status(for permission: Permission) async -> PermissionStatus {
    switch permission {
    case .microphone:
      return PermissionStatus(authorizationStatus: statusSource(.audio))
    case .systemAudio:
      return .notDetermined  // handled by the later system-audio tap probe
    }
  }

  public func request(_ permission: Permission) async -> PermissionStatus {
    switch permission {
    case .microphone:
      return await accessRequester(.audio) ? .authorized : .denied
    case .systemAudio:
      return .notDetermined  // handled by the later system-audio tap probe
    }
  }
}
