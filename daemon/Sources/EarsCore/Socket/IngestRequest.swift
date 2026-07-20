/// The ingest WebSocket's two text-frame commands — the **v1 ingest
/// contract, unchanged by control protocol v2** (`/ingest` is explicitly out
/// of v2's scope): a flat `cmd`-tagged envelope, answered with the
/// `{"ok":…}` ``ControlResponse`` shape.
///
/// ```jsonc
/// {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
/// {"cmd":"ingest.close","stream_id":"s7"}
/// ```
public enum IngestRequest: Sendable, Hashable {
  /// Begin pushing audio for a `browser:<label>` source; declares its format.
  case open(source: SourceID, format: AudioFormatSpec)
  /// End a stream opened by `ingest.open`, by its `stream_id`.
  case close(streamID: String)
}

extension IngestRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case cmd, source, format
    case streamID = "stream_id"
  }

  private enum Tag: String, Codable {
    case open = "ingest.open"
    case close = "ingest.close"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Tag.self, forKey: .cmd) {
    case .open:
      self = .open(
        source: try container.decode(SourceID.self, forKey: .source),
        format: try container.decode(AudioFormatSpec.self, forKey: .format))
    case .close:
      self = .close(streamID: try container.decode(String.self, forKey: .streamID))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .open(let source, let format):
      try container.encode(Tag.open, forKey: .cmd)
      try container.encode(source, forKey: .source)
      try container.encode(format, forKey: .format)
    case .close(let streamID):
      try container.encode(Tag.close, forKey: .cmd)
      try container.encode(streamID, forKey: .streamID)
    }
  }
}
