/// What opened a session, mirroring `session.toml`'s `trigger` field.
public enum TriggerKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Opened automatically by an app-signal trigger (e.g. a meeting app launching).
  case appSignal = "app-signal"
  /// Opened by an explicit user action.
  case manual
}
