/// One line of a source's `index.jsonl` (see `docs/data-formats.md`).
///
/// The index is append-only JSON Lines, one event per line, ordered by time.
/// Each case mirrors one of the four documented event shapes exactly,
/// discriminated on disk by the `"t"` field:
///
/// ```jsonc
/// {"t":"chunk","start":...,"end":...,"file":...,"frames":...}
/// {"t":"vad","state":"speech"|"silence","start":...,"end":...}
/// {"t":"gap","start":...,"end":...,"reason":...}
/// {"t":"evict","file":...,"start":...}
/// ```
///
/// `start`/`end` are ISO-8601 UTC timestamps on disk, decoded to ``Instant``
/// via ``IndexTimestampCodec`` (not `Instant`'s own `Codable`, which is a
/// plain-`Double` seconds-since-epoch form — see that type's doc comment).
public enum IndexEvent: Sendable, Hashable {
  /// A written audio chunk covering `[start, end)`.
  case chunk(start: Instant, end: Instant, file: String, frames: Int)
  /// A VAD-classified span, possibly spanning chunk boundaries.
  case vad(state: VADState, start: Instant, end: Instant)
  /// A known capture gap (daemon down, device lost, pause).
  case gap(start: Instant, end: Instant, reason: String)
  /// The eviction of an aged-out chunk.
  case evict(file: String, start: Instant)

  /// The instant used to order events within the index. Every case carries
  /// a `start`; this is the sort key ``IndexLog`` uses to defend against
  /// out-of-order lines (see that type's doc comment).
  public var start: Instant {
    switch self {
    case .chunk(let start, _, _, _): start
    case .vad(_, let start, _): start
    case .gap(let start, _, _): start
    case .evict(_, let start): start
    }
  }

  /// Which on-disk log this event belongs to once the index is split into a
  /// small structural log and a segmented VAD stream (see
  /// `docs/data-formats.md`'s "The index").
  ///
  /// The split exists because `vad` events dominate the index by volume
  /// (measured at ~98% of a long-running mic source), yet are needed only when
  /// reconstructing a specific time range — never at startup, where only the
  /// chunk/evict/gap events are consulted to recover the live chunk set. Keeping
  /// them apart means a daemon restart parses the tiny structural log, not the
  /// whole history.
  public var stream: IndexStream {
    switch self {
    case .vad: .vad
    case .chunk, .gap, .evict: .structural
    }
  }
}

/// The two on-disk logs a source's index is split across, keyed by
/// ``IndexEvent/stream``.
public enum IndexStream: Sendable, Hashable, CaseIterable {
  /// `chunk`/`gap`/`evict` — the small, whole-history log read at startup to
  /// reconstruct the live chunk set. Written to `chunks.jsonl`.
  case structural
  /// `vad` — the high-volume speech/silence spans, read only per requested
  /// range. Written to size/time-rotated segments under `vad/`.
  case vad
}

extension IndexEvent: Codable {
  fileprivate enum CodingKeys: String, CodingKey {
    case t, start, end, file, frames, state, reason
  }

  private enum Tag: String, Codable {
    case chunk, vad, gap, evict
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(Tag.self, forKey: .t)
    switch tag {
    case .chunk:
      self = .chunk(
        start: try container.decodeInstant(forKey: .start),
        end: try container.decodeInstant(forKey: .end),
        file: try container.decode(String.self, forKey: .file),
        frames: try container.decode(Int.self, forKey: .frames)
      )
    case .vad:
      self = .vad(
        state: try container.decode(VADState.self, forKey: .state),
        start: try container.decodeInstant(forKey: .start),
        end: try container.decodeInstant(forKey: .end)
      )
    case .gap:
      self = .gap(
        start: try container.decodeInstant(forKey: .start),
        end: try container.decodeInstant(forKey: .end),
        reason: try container.decode(String.self, forKey: .reason)
      )
    case .evict:
      self = .evict(
        file: try container.decode(String.self, forKey: .file),
        start: try container.decodeInstant(forKey: .start)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .chunk(let start, let end, let file, let frames):
      try container.encode(Tag.chunk, forKey: .t)
      try container.encodeInstant(start, forKey: .start)
      try container.encodeInstant(end, forKey: .end)
      try container.encode(file, forKey: .file)
      try container.encode(frames, forKey: .frames)
    case .vad(let state, let start, let end):
      try container.encode(Tag.vad, forKey: .t)
      try container.encode(state, forKey: .state)
      try container.encodeInstant(start, forKey: .start)
      try container.encodeInstant(end, forKey: .end)
    case .gap(let start, let end, let reason):
      try container.encode(Tag.gap, forKey: .t)
      try container.encodeInstant(start, forKey: .start)
      try container.encodeInstant(end, forKey: .end)
      try container.encode(reason, forKey: .reason)
    case .evict(let file, let start):
      try container.encode(Tag.evict, forKey: .t)
      try container.encode(file, forKey: .file)
      try container.encodeInstant(start, forKey: .start)
    }
  }
}

extension KeyedDecodingContainer<IndexEvent.CodingKeys> {
  fileprivate func decodeInstant(forKey key: IndexEvent.CodingKeys) throws -> Instant {
    let raw = try decode(String.self, forKey: key)
    guard let instant = IndexTimestampCodec.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: self,
        debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
      )
    }
    return instant
  }
}

extension KeyedEncodingContainer<IndexEvent.CodingKeys> {
  fileprivate mutating func encodeInstant(_ instant: Instant, forKey key: IndexEvent.CodingKeys)
    throws
  {
    try encode(IndexTimestampCodec.format(instant), forKey: key)
  }
}
