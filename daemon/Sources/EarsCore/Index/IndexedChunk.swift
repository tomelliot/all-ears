/// A written audio chunk as known from the index, i.e. an ``IndexEvent/chunk``
/// event's payload lifted into its own type.
///
/// Separate from `IndexEvent.chunk`'s associated values so that reconstruction
/// (``RangeReconstructor``) and eviction (``RingBufferEviction``) have a clean,
/// self-contained type to hand callers instead of an enum case.
public struct IndexedChunk: Sendable, Hashable {
  /// The chunk's wall-clock coverage, `[range.start, range.end)`.
  public var range: TimeRange
  /// Path to the chunk file, relative to the source directory (e.g.
  /// `chunks/2026-07-17T10-30-00Z.m4a`).
  public var file: String
  /// Frame count, as written by the capture backend.
  public var frames: Int

  public init(range: TimeRange, file: String, frames: Int) {
    self.range = range
    self.file = file
    self.frames = frames
  }
}
