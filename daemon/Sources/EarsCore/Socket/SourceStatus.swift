/// The per-source payload shared by `status` and `sources.list` responses.
///
/// **Wire-shape decision:** `docs/specs/capture-daemon.md` gives one literal
/// example field set for this — `id`/`state`/`codec` — but `status`'s
/// one-line spec also promises "buffer occupancy", and `sources.list`
/// carries the same per-source shape. This adds three fields beyond the
/// spec's example: ``oldestChunkStart`` and ``newestChunkEnd`` (both
/// ISO-8601, rendered the same way ``IndexTimestampCodec`` renders
/// `index.jsonl` timestamps) bound the source's current ring-buffer window,
/// and ``bytesUsed`` (bytes) reports its on-disk footprint. All three are
/// optional/defaulted on decode — ``oldestChunkStart``/``newestChunkEnd``
/// are `nil` and ``bytesUsed`` is `0` when absent — so the spec's original
/// minimal example still decodes cleanly.
public struct SourceStatus: Sendable, Hashable {
  public var id: SourceID
  public var state: SourceRuntimeState
  public var codec: String
  /// Start of the oldest chunk still on disk for this source, or `nil` if
  /// its buffer is empty.
  public var oldestChunkStart: Instant?
  /// End of the newest chunk written for this source, or `nil` if its
  /// buffer is empty.
  public var newestChunkEnd: Instant?
  /// Bytes currently used by this source's on-disk buffer.
  public var bytesUsed: Int

  public init(
    id: SourceID,
    state: SourceRuntimeState,
    codec: String,
    oldestChunkStart: Instant? = nil,
    newestChunkEnd: Instant? = nil,
    bytesUsed: Int = 0
  ) {
    self.id = id
    self.state = state
    self.codec = codec
    self.oldestChunkStart = oldestChunkStart
    self.newestChunkEnd = newestChunkEnd
    self.bytesUsed = bytesUsed
  }
}

extension SourceStatus: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, state, codec
    case oldestChunkStart = "oldest_chunk_start"
    case newestChunkEnd = "newest_chunk_end"
    case bytesUsed = "bytes_used"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(SourceID.self, forKey: .id)
    state = try container.decode(SourceRuntimeState.self, forKey: .state)
    codec = try container.decode(String.self, forKey: .codec)
    oldestChunkStart = try container.decodeISO8601InstantIfPresent(forKey: .oldestChunkStart)
    newestChunkEnd = try container.decodeISO8601InstantIfPresent(forKey: .newestChunkEnd)
    bytesUsed = try container.decodeIfPresent(Int.self, forKey: .bytesUsed) ?? 0
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(state, forKey: .state)
    try container.encode(codec, forKey: .codec)
    try container.encodeISO8601InstantIfPresent(oldestChunkStart, forKey: .oldestChunkStart)
    try container.encodeISO8601InstantIfPresent(newestChunkEnd, forKey: .newestChunkEnd)
    try container.encode(bytesUsed, forKey: .bytesUsed)
  }
}
