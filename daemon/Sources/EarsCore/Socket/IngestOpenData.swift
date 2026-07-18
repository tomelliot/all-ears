/// `ingest.open`'s response `data` payload, matching the spec's literal
/// example (`docs/specs/capture-daemon.md`): `{"ok":true,"data":{"stream_id":"s7"}}`.
public struct IngestOpenData: Sendable, Hashable, Codable {
  public var streamID: String

  public init(streamID: String) {
    self.streamID = streamID
  }

  private enum CodingKeys: String, CodingKey {
    case streamID = "stream_id"
  }
}
