import EarsCore
import Foundation

/// Appends `vad` events to a source's segmented VAD stream under `vad/`, per
/// `docs/data-formats.md`'s "The index": the high-volume speech/silence spans
/// live apart from the small structural log (`chunks.jsonl`) so a daemon
/// restart never parses them, and they age out by whole-segment `unlink`
/// (``VADSegmentStore/evict(directory:olderThan:)``) rather than by rewriting a
/// growing file.
///
/// A new segment opens when the current one crosses either bound — a byte cap
/// (so any single segment's parse cost is bounded regardless of speech density)
/// or a wall-clock span (so eviction granularity tracks the time cap). Segments
/// are append-only and named by their first event's start, so nothing that
/// tails them (``VADSegmentTailReader``) is ever invalidated by a rewrite.
///
/// An `actor`, mirroring ``IndexAppender``: one writer per source serialises the
/// segment-rollover decision against the appends it guards.
public actor VADSegmentWriter {
  private let directory: URL
  private let maxSegmentBytes: Int
  private let maxSegmentSeconds: Double
  private let encoder = JSONEncoder()

  private var currentURL: URL?
  private var currentStart: Instant?
  private var currentBytes = 0
  private var primed = false

  /// - Parameters:
  ///   - directory: The source's `vad/` directory (``DataStoreLayout/vadDirectory``).
  ///   - maxSegmentBytes: Roll over once a segment would exceed this. Default
  ///     8 MB — a few hundred thousand VAD lines, well under what a single
  ///     range read parses.
  ///   - maxSegmentSeconds: Roll over once a segment spans this much wall-clock.
  ///     Default 1 h, so eviction drops whole hours cleanly.
  public init(directory: URL, maxSegmentBytes: Int = 8_388_608, maxSegmentSeconds: Double = 3600) {
    self.directory = directory
    self.maxSegmentBytes = maxSegmentBytes
    self.maxSegmentSeconds = maxSegmentSeconds
  }

  /// Appends one `vad` span, opening (or rolling over to) a segment as needed.
  /// Flushes before returning so a concurrent tail or a crash always sees whole
  /// lines, exactly like ``IndexAppender/append(_:)``.
  public func append(state: VADState, start: Instant, end: Instant) throws {
    primeIfNeeded()
    var line = try encoder.encode(IndexEvent.vad(state: state, start: start, end: end))
    line.append(UInt8(ascii: "\n"))

    if shouldRollOver(at: start, addingBytes: line.count) {
      try openSegment(start: start)
    } else if currentURL == nil {
      try openSegment(start: start)
    }

    guard let url = currentURL else { return }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try handle.synchronize()
    currentBytes += line.count
  }

  private func shouldRollOver(at start: Instant, addingBytes bytes: Int) -> Bool {
    guard let currentStart else { return false }
    if currentBytes + bytes > maxSegmentBytes { return true }
    if start.interval(since: currentStart) >= maxSegmentSeconds { return true }
    return false
  }

  /// Resumes into the newest existing segment on first append (a daemon restart
  /// continues the last segment rather than orphaning it), reading its byte size
  /// and start once. No-op after the first call.
  private func primeIfNeeded() {
    guard !primed else { return }
    primed = true
    guard let newest = VADSegmentStore.segmentURLs(directory: directory).last else { return }
    currentURL = newest.url
    currentStart = newest.start
    let size = (try? FileManager.default.attributesOfItem(atPath: newest.url.path))?[.size]
    currentBytes = (size as? NSNumber)?.intValue ?? 0
  }

  private func openSegment(start: Instant) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(
      "\(FilenameTimestampCodec.string(for: start)).jsonl")
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw DataStoreIOError.fsyncFailed(path: url.path, errno: 0)
      }
    }
    currentURL = url
    currentStart = start
    currentBytes =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .intValue ?? 0
  }
}
