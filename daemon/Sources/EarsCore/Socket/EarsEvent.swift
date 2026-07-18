/// One pub/sub live-feed event, matching
/// `docs/specs/capture-daemon.md`'s literal event-stream examples exactly,
/// discriminated on the wire by `"ev"` (mirroring ``IndexEvent``'s `"t"`-tag
/// pattern for `index.jsonl` and ``ControlRequest``'s `"cmd"`-tag pattern):
///
/// ```jsonc
/// {"ev":"vad","source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}
/// {"ev":"session","id":"...standup","state":"open"}
/// {"ev":"segment","session":"...standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}
/// ```
public enum EarsEvent: Sendable, Hashable {
  /// A VAD state change on `source` at wall-clock instant `t`.
  case vad(source: SourceID, state: VADState, t: Instant)
  /// A session's lifecycle changed.
  case session(id: String, state: SessionState)
  /// A transcribed segment, published by a `transcribe --follow` process so
  /// many consumers can watch one live transcript. `start`/`end` are
  /// seconds relative to the session's range start, matching ``Segment``'s
  /// own offsets.
  case segment(session: String, speaker: String, start: Double, end: Double, text: String)
}

extension EarsEvent: Codable {
  fileprivate enum CodingKeys: String, CodingKey {
    case ev, source, state, t, id, session, speaker, start, end, text
  }

  private enum Tag: String, Codable {
    case vad, session, segment
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(Tag.self, forKey: .ev)
    switch tag {
    case .vad:
      self = .vad(
        source: try container.decode(SourceID.self, forKey: .source),
        state: try container.decode(VADState.self, forKey: .state),
        t: try container.decodeISO8601Instant(forKey: .t)
      )
    case .session:
      self = .session(
        id: try container.decode(String.self, forKey: .id),
        state: try container.decode(SessionState.self, forKey: .state)
      )
    case .segment:
      self = .segment(
        session: try container.decode(String.self, forKey: .session),
        speaker: try container.decode(String.self, forKey: .speaker),
        start: try container.decode(Double.self, forKey: .start),
        end: try container.decode(Double.self, forKey: .end),
        text: try container.decode(String.self, forKey: .text)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .vad(let source, let state, let t):
      try container.encode(Tag.vad, forKey: .ev)
      try container.encode(source, forKey: .source)
      try container.encode(state, forKey: .state)
      try container.encodeISO8601Instant(t, forKey: .t)
    case .session(let id, let state):
      try container.encode(Tag.session, forKey: .ev)
      try container.encode(id, forKey: .id)
      try container.encode(state, forKey: .state)
    case .segment(let session, let speaker, let start, let end, let text):
      try container.encode(Tag.segment, forKey: .ev)
      try container.encode(session, forKey: .session)
      try container.encode(speaker, forKey: .speaker)
      try container.encode(start, forKey: .start)
      try container.encode(end, forKey: .end)
      try container.encode(text, forKey: .text)
    }
  }
}
