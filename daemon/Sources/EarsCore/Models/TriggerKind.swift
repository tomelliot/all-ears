/// What opened a session, mirroring `session.toml`'s `trigger` field.
public enum TriggerKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Opened automatically by an app-signal trigger (e.g. a meeting app launching).
  case appSignal = "app-signal"
  /// Opened by an explicit user action.
  case manual
  /// Opened by the browser extension over the control-plane WebSocket (e.g. a
  /// Google Meet call starting in a tab) — neither a literal CLI invocation
  /// nor an OS-level app-launch signal, so it gets its own provenance value.
  case browserExtension = "browser-extension"
}
