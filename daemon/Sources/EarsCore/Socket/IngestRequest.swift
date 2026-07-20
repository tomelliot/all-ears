/// The ingest WebSocket's two text-frame commands — the **v1 ingest
/// contract** (`/ingest` is explicitly out of control protocol v2's scope): a
/// flat `cmd`-tagged envelope, answered with the `{"ok":…}` ``ControlResponse``
/// shape.
///
/// ```jsonc
/// {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
/// {"cmd":"ingest.open","source":"browser:meet:dev-2","format":{…},"meeting":{"platform":"meet","external_id":"kQ0DRVtDaekB"}}
/// {"cmd":"ingest.close","stream_id":"s7"}
/// ```
///
/// `meeting` is optional: when present, the daemon links the source into that
/// meeting's membership itself (see `MeetingRegistry.ingestStreamOpened`), so
/// the ingest-idle grace policy holds even when the client's own
/// `meeting.attendee` source upserts never arrive (an MV3 service worker that
/// lost its in-memory state mid-call). Untagged opens behave exactly as
/// before.
public enum IngestRequest: Sendable, Hashable {
  /// Begin pushing audio for a `browser:<label>` source; declares its format
  /// and (optionally) the meeting identity the source belongs to.
  case open(source: SourceID, format: AudioFormatSpec, meeting: MeetingIdentity?)
  /// End a stream opened by `ingest.open`, by its `stream_id`.
  case close(streamID: String)
}

extension IngestRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case cmd, source, format, meeting
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
        format: try container.decode(AudioFormatSpec.self, forKey: .format),
        meeting: try container.decodeIfPresent(MeetingIdentity.self, forKey: .meeting))
    case .close:
      self = .close(streamID: try container.decode(String.self, forKey: .streamID))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .open(let source, let format, let meeting):
      try container.encode(Tag.open, forKey: .cmd)
      try container.encode(source, forKey: .source)
      try container.encode(format, forKey: .format)
      try container.encodeIfPresent(meeting, forKey: .meeting)
    case .close(let streamID):
      try container.encode(Tag.close, forKey: .cmd)
      try container.encode(streamID, forKey: .streamID)
    }
  }
}
