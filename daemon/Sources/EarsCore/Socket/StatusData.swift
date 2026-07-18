/// `status`'s response `data` payload, matching the spec's literal example
/// (`docs/specs/capture-daemon.md`) plus the buffer-occupancy fields added
/// to ``SourceStatus`` — see that type's doc comment for the wire-shape
/// decision.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]

  public init(uptimeSeconds: Int, sources: [SourceStatus]) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources
  }
}
