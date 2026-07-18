/// Lifecycle state of a session, mirroring `session.toml`'s `state` field.
public enum SessionState: String, Sendable, Hashable, Codable, CaseIterable {
  /// The session is live; its `end` is not yet set.
  case open
  /// The session has been closed and its range is final.
  case closed
}
