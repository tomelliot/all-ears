/// `status`'s result payload: daemon + per-source state (with buffer
/// occupancy, see ``SourceStatus``), plus the active meetings and sessions —
/// v2 widened the v1 shape with the `meetings`/`sessions` lists.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]
  public var meetings: [Meeting]
  public var sessions: [SessionSummary]

  public init(
    uptimeSeconds: Int, sources: [SourceStatus], meetings: [Meeting] = [],
    sessions: [SessionSummary] = []
  ) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
    self.meetings = meetings
    self.sessions = sessions
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources, meetings, sessions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    sources = try container.decode([SourceStatus].self, forKey: .sources)
    meetings = try container.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
    sessions = try container.decodeIfPresent([SessionSummary].self, forKey: .sessions) ?? []
  }
}
