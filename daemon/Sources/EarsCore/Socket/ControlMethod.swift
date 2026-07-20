/// Every v2 method name, with the capability each requires
/// (`docs/specs/control-protocol.md`'s "Methods" table). `hello` is
/// the one method with no capability — it *establishes* the connection's
/// capabilities.
public enum ControlMethod: String, Sendable, Hashable, Codable, CaseIterable {
  case hello

  case status
  case subscribe

  case meetingStart = "meeting.start"
  case meetingEnd = "meeting.end"
  case meetingPause = "meeting.pause"
  case meetingResume = "meeting.resume"
  case meetingRename = "meeting.rename"
  case meetingAttendee = "meeting.attendee"
  case meetingList = "meeting.list"
  case meetingGet = "meeting.get"

  case sessionOpen = "session.open"
  case sessionClose = "session.close"
  case sessionList = "session.list"
  case sessionAddSource = "session.add_source"
  case mark
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
    case .meetingStart, .meetingEnd, .meetingPause, .meetingResume, .meetingRename,
      .meetingAttendee, .meetingList, .meetingGet:
      return .meetings
    case .sessionOpen, .sessionClose, .sessionList, .sessionAddSource, .mark,
      .segmentPublish, .jobPublish:
      return .sessions
    case .sourcesList, .sourcesEnable, .sourcesDisable:
      return .sources
    case .sourcesAdd, .sourcesRemove, .capturePause, .captureResume, .flush:
      return .admin
    }
  }
}
