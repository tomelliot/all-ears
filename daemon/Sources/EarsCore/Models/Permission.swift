/// A macOS privacy permission a source may require, queried through
/// ``PermissionProviding``.
///
/// - Note: Provisional. The daemon captures mic and system/app audio today; more
///   cases (e.g. accessibility for app-signal triggers) are expected as later
///   phases exercise real capture.
public enum Permission: String, Sendable, Hashable, Codable, CaseIterable {
  /// Microphone input (`mic` / `device` sources).
  case microphone
  /// System-audio recording via a process tap (`system` / `app` sources). macOS
  /// exposes no query API for this grant; the shim probes it by creating and
  /// destroying a throwaway tap and by detecting an all-zero PCM stream.
  case systemAudio
}
