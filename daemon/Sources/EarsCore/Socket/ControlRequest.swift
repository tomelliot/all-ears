/// One control-socket request: the fourteen `cmd`s in
/// `docs/specs/capture-daemon.md`'s control-socket command table.
///
/// Each case mirrors one row of the spec's table, discriminated on disk by
/// the `"cmd"` field — the same flat-tagged-union shape ``IndexEvent`` uses
/// for `index.jsonl`'s `"t"` field:
///
/// ```jsonc
/// {"cmd":"status"}
/// {"cmd":"sources.list"}
/// {"cmd":"sources.add","spec":{"id":"app:us.zoom.xos","class":"app", ...}}
/// {"cmd":"sources.remove","source":"app:us.zoom.xos"}
/// {"cmd":"sources.enable","source":"app:us.zoom.xos"}
/// {"cmd":"sources.disable","source":"app:us.zoom.xos"}
/// {"cmd":"capture.pause","source":"mic"}       // source omitted => all sources
/// {"cmd":"capture.resume","source":"mic"}      // source omitted => all sources
/// {"cmd":"session.open","sources":["mic"],"slug":"standup","start":"...","vocab":"..."}
/// {"cmd":"session.close","id":"2026-07-17T10-30-00Z_standup"}
/// {"cmd":"session.list"}
/// {"cmd":"mark","sources":["mic"],"slug":"hallway-chat","last_seconds":1800}
/// {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":48000,"channels":1,"encoding":"pcm_s16le"}}
/// {"cmd":"flush"}
/// ```
///
/// `sources.add`'s payload nests under `"spec"` (a ``SourceSpec``, see that
/// type's doc comment for why its shape is inferred rather than literal) so
/// its many fields don't flatten into this type's `CodingKeys`; every other
/// command's fields sit flat alongside `"cmd"`, matching the spec's literal
/// examples exactly. See ``MarkRange`` for the `mark` wire-shape decision.
public enum ControlRequest: Sendable, Hashable {
  /// Daemon + per-source state, buffer occupancy, active sessions.
  case status
  /// All configured sources and state.
  case sourcesList
  /// Add a source at runtime.
  case sourcesAdd(SourceSpec)
  /// Remove a source at runtime.
  case sourcesRemove(source: SourceID)
  /// Start capturing a source.
  case sourcesEnable(source: SourceID)
  /// Stop capturing a source.
  case sourcesDisable(source: SourceID)
  /// Pause a source, or all sources when `source` is `nil` (records a `gap`).
  case capturePause(source: SourceID?)
  /// Resume a source, or all sources when `source` is `nil`.
  case captureResume(source: SourceID?)
  /// Open a session across `sources`, named `slug`; `start` defaults to now
  /// when `nil`, `vocab` names an optional per-session vocabulary file.
  case sessionOpen(sources: [SourceID], slug: String, start: Instant?, vocab: String?)
  /// Close a session by id (sets `end`, `state = closed`).
  case sessionClose(id: String)
  /// Open/recent sessions.
  case sessionList
  /// Retroactively define a range as a session — see ``MarkRange``.
  case mark(sources: [SourceID], slug: String, range: MarkRange)
  /// Begin pushing audio for a `browser:<label>` source; declares its format.
  case ingestOpen(source: SourceID, format: AudioFormatSpec)
  /// Force-flush in-flight chunks and index.
  case flush
}

extension ControlRequest: Codable {
  fileprivate enum CodingKeys: String, CodingKey {
    case cmd, spec, source, sources, slug, start, end, vocab, id, format
    case lastSeconds = "last_seconds"
  }

  private enum Tag: String, Codable {
    case status
    case sourcesList = "sources.list"
    case sourcesAdd = "sources.add"
    case sourcesRemove = "sources.remove"
    case sourcesEnable = "sources.enable"
    case sourcesDisable = "sources.disable"
    case capturePause = "capture.pause"
    case captureResume = "capture.resume"
    case sessionOpen = "session.open"
    case sessionClose = "session.close"
    case sessionList = "session.list"
    case mark
    case ingestOpen = "ingest.open"
    case flush
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(Tag.self, forKey: .cmd)
    switch tag {
    case .status:
      self = .status
    case .sourcesList:
      self = .sourcesList
    case .sourcesAdd:
      self = .sourcesAdd(try container.decode(SourceSpec.self, forKey: .spec))
    case .sourcesRemove:
      self = .sourcesRemove(source: try container.decode(SourceID.self, forKey: .source))
    case .sourcesEnable:
      self = .sourcesEnable(source: try container.decode(SourceID.self, forKey: .source))
    case .sourcesDisable:
      self = .sourcesDisable(source: try container.decode(SourceID.self, forKey: .source))
    case .capturePause:
      self = .capturePause(source: try container.decodeIfPresent(SourceID.self, forKey: .source))
    case .captureResume:
      self = .captureResume(source: try container.decodeIfPresent(SourceID.self, forKey: .source))
    case .sessionOpen:
      self = .sessionOpen(
        sources: try container.decode([SourceID].self, forKey: .sources),
        slug: try container.decode(String.self, forKey: .slug),
        start: try container.decodeISO8601InstantIfPresent(forKey: .start),
        vocab: try container.decodeIfPresent(String.self, forKey: .vocab)
      )
    case .sessionClose:
      self = .sessionClose(id: try container.decode(String.self, forKey: .id))
    case .sessionList:
      self = .sessionList
    case .mark:
      self = .mark(
        sources: try container.decode([SourceID].self, forKey: .sources),
        slug: try container.decode(String.self, forKey: .slug),
        range: try Self.decodeMarkRange(from: container)
      )
    case .ingestOpen:
      self = .ingestOpen(
        source: try container.decode(SourceID.self, forKey: .source),
        format: try container.decode(AudioFormatSpec.self, forKey: .format)
      )
    case .flush:
      self = .flush
    }
  }

  /// Decodes `mark`'s dual-shape range field — see ``MarkRange``'s doc
  /// comment for the wire-shape decision this implements.
  private static func decodeMarkRange(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> MarkRange {
    let lastSeconds = try container.decodeIfPresent(Double.self, forKey: .lastSeconds)
    let hasAbsolute = container.contains(.start) || container.contains(.end)
    switch (lastSeconds, hasAbsolute) {
    case (let seconds?, false):
      return .lastSeconds(seconds)
    case (nil, true):
      return .absolute(
        start: try container.decodeISO8601Instant(forKey: .start),
        end: try container.decodeISO8601Instant(forKey: .end)
      )
    case (nil, false):
      throw DecodingError.dataCorruptedError(
        forKey: .lastSeconds, in: container,
        debugDescription: "mark requires either last_seconds or start+end")
    case (_, true):
      throw DecodingError.dataCorruptedError(
        forKey: .lastSeconds, in: container,
        debugDescription: "mark accepts either last_seconds or start+end, not both")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .status:
      try container.encode(Tag.status, forKey: .cmd)
    case .sourcesList:
      try container.encode(Tag.sourcesList, forKey: .cmd)
    case .sourcesAdd(let spec):
      try container.encode(Tag.sourcesAdd, forKey: .cmd)
      try container.encode(spec, forKey: .spec)
    case .sourcesRemove(let source):
      try container.encode(Tag.sourcesRemove, forKey: .cmd)
      try container.encode(source, forKey: .source)
    case .sourcesEnable(let source):
      try container.encode(Tag.sourcesEnable, forKey: .cmd)
      try container.encode(source, forKey: .source)
    case .sourcesDisable(let source):
      try container.encode(Tag.sourcesDisable, forKey: .cmd)
      try container.encode(source, forKey: .source)
    case .capturePause(let source):
      try container.encode(Tag.capturePause, forKey: .cmd)
      try container.encodeIfPresent(source, forKey: .source)
    case .captureResume(let source):
      try container.encode(Tag.captureResume, forKey: .cmd)
      try container.encodeIfPresent(source, forKey: .source)
    case .sessionOpen(let sources, let slug, let start, let vocab):
      try container.encode(Tag.sessionOpen, forKey: .cmd)
      try container.encode(sources, forKey: .sources)
      try container.encode(slug, forKey: .slug)
      try container.encodeISO8601InstantIfPresent(start, forKey: .start)
      try container.encodeIfPresent(vocab, forKey: .vocab)
    case .sessionClose(let id):
      try container.encode(Tag.sessionClose, forKey: .cmd)
      try container.encode(id, forKey: .id)
    case .sessionList:
      try container.encode(Tag.sessionList, forKey: .cmd)
    case .mark(let sources, let slug, let range):
      try container.encode(Tag.mark, forKey: .cmd)
      try container.encode(sources, forKey: .sources)
      try container.encode(slug, forKey: .slug)
      switch range {
      case .lastSeconds(let seconds):
        try container.encode(seconds, forKey: .lastSeconds)
      case .absolute(let start, let end):
        try container.encodeISO8601Instant(start, forKey: .start)
        try container.encodeISO8601Instant(end, forKey: .end)
      }
    case .ingestOpen(let source, let format):
      try container.encode(Tag.ingestOpen, forKey: .cmd)
      try container.encode(source, forKey: .source)
      try container.encode(format, forKey: .format)
    case .flush:
      try container.encode(Tag.flush, forKey: .cmd)
    }
  }
}
