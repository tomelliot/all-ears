/// Every v2 method name, with the capability each requires
/// (`docs/specs/control-protocol.md`'s "Methods" table). `hello` is
/// the one method with no capability — it *establishes* the connection's
/// capabilities.
public enum ControlMethod: String, Sendable, Hashable, Codable, CaseIterable {
  case hello

  case status
  case subscribe

  case sessionStart = "session.start"
  case sessionEnd = "session.end"
  case sessionPause = "session.pause"
  case sessionResume = "session.resume"
  case sessionRename = "session.rename"
  case sessionAttendee = "session.attendee"
  case sessionList = "session.list"
  case sessionGet = "session.get"
  case sessionRetry = "session.retry"

  case segmentPublish = "segment.publish"
  case jobPublish = "job.publish"

  case sourcesList = "sources.list"
  case sourcesEnable = "sources.enable"
  case sourcesDisable = "sources.disable"

  case sourcesAdd = "sources.add"
  case sourcesRemove = "sources.remove"
  case capturePause = "capture.pause"
  case captureResume = "capture.resume"
  case flush

  /// The capability a connection needs to invoke this method; `nil` only for
  /// `hello`. Transports enforce this before dispatch (`not_permitted`).
  public var capability: Capability? {
    switch self {
    case .hello:
      return nil
    case .status, .subscribe:
      return .observe
    case .sessionStart, .sessionEnd, .sessionPause, .sessionResume, .sessionRename,
      .sessionAttendee, .sessionList, .sessionGet:
      return .sessions
    case .segmentPublish, .jobPublish:
      return .publish
    case .sourcesList, .sourcesEnable, .sourcesDisable:
      return .sources
    // `session.retry` spawns the LLM stages, so the loopback WebSocket's
    // `sessions` tier does not reach it.
    case .sourcesAdd, .sourcesRemove, .capturePause, .captureResume, .flush, .sessionRetry:
      return .admin
    }
  }
}
