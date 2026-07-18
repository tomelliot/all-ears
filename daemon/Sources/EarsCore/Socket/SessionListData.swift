/// `session.list`'s response `data` payload: "Open/recent sessions"
/// (`docs/specs/capture-daemon.md`), as ``SessionSummary``'s wire shape.
public struct SessionListData: Sendable, Hashable, Codable {
  public var sessions: [SessionSummary]

  public init(sessions: [SessionSummary]) {
    self.sessions = sessions
  }
}
