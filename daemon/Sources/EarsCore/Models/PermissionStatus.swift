/// The resolved state of a ``Permission``.
///
/// Mirrors the shape of the platform TCC states so a shim can map to them without
/// leaking platform types into pure code. A denial disables only the affected
/// source (never the daemon) and should surface an actionable message naming the
/// exact Settings pane.
public enum PermissionStatus: String, Sendable, Hashable, Codable, CaseIterable {
  /// Granted.
  case authorized
  /// Explicitly denied by the user.
  case denied
  /// Not yet requested; a prompt can still be shown.
  case notDetermined
  /// Blocked by policy (e.g. MDM); the user cannot grant it.
  case restricted
}
