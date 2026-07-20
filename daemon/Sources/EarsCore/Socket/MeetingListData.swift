/// `meeting.list`'s result: active + recent meetings. Closed history is read
/// from disk (`ears meeting list --all`), not the socket.
public struct MeetingListData: Sendable, Hashable, Codable {
  public var meetings: [Meeting]

  public init(meetings: [Meeting]) {
    self.meetings = meetings
  }
}
