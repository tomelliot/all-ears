/// `meeting.resolve`'s response `data` payload: the daemon-assigned meeting
/// id (a UUID string) for the requested `(platform, external_id)` pair —
/// pre-existing when the pair was seen before (rejoin), freshly minted
/// otherwise. Mirrors ``SessionOpenData``'s "returns an id" shape.
public struct MeetingResolveData: Sendable, Hashable, Codable {
  public var meetingID: String

  public init(meetingID: String) {
    self.meetingID = meetingID
  }

  private enum CodingKeys: String, CodingKey {
    case meetingID = "meeting_id"
  }
}
