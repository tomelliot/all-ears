import EarsCore
import Foundation

/// Read and maintenance side of the segmented VAD stream that
/// ``VADSegmentWriter`` produces under a source's `vad/` directory.
///
/// Segments are append-only files named by their first event's start
/// (``FilenameTimestampCodec``), so their filenames alone order them in time and
/// bound which ones a query or an eviction must touch — no segment body is read
/// to decide either.
public enum VADSegmentStore {
  /// The source's VAD segments, oldest-first, each paired with the start parsed
  /// from its filename. Non-`.jsonl` entries and unparseable names are skipped.
  public static func segmentURLs(directory: URL) -> [(url: URL, start: Instant)] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return
      entries
      .filter { $0.pathExtension == "jsonl" }
      .compactMap { url -> (url: URL, start: Instant)? in
        guard
          let start = FilenameTimestampCodec.parse(url.deletingPathExtension().lastPathComponent)
        else { return nil }
        return (url, start)
      }
      .sorted { $0.start < $1.start }
  }

  /// Every `vad` event overlapping `range`, gathered from the segments that can
  /// contain it. A segment is read when it could hold an event inside `range`:
  /// its own start is at or before `range.end`, and it is either the last
  /// segment starting at/before `range.start` or starts within the range. Events
  /// are returned unsorted (``RangeReconstructor`` sorts).
  public static func events(directory: URL, overlapping range: TimeRange) -> [IndexEvent] {
    let segments = segmentURLs(directory: directory)
    guard !segments.isEmpty else { return [] }

    // The newest segment whose start is <= range.start may still carry events
    // reaching into the range, so include it and everything after, up to the
    // last segment starting before range.end.
    var startIndex = 0
    for (i, segment) in segments.enumerated() where segment.start <= range.start {
      startIndex = i
    }

    var events: [IndexEvent] = []
    for segment in segments[startIndex...]
    where segment.start < range.end || segment.start <= range.start {
      guard let contents = try? String(contentsOf: segment.url, encoding: .utf8) else { continue }
      events.append(contentsOf: IndexLog.parse(contents).events)
    }
    return events
  }

  /// The latest `end` across the newest segment — the VAD stream's contribution
  /// to startup gap detection. Reads only the newest segment (its events are the
  /// most recent), returning `nil` when there are none.
  public static func lastKnownEnd(directory: URL) -> Instant? {
    guard let newest = segmentURLs(directory: directory).last,
      let contents = try? String(contentsOf: newest.url, encoding: .utf8)
    else { return nil }
    return IndexLog.parse(contents).events.compactMap {
      if case .vad(_, _, let end) = $0 { return end }
      return nil
    }.max()
  }

  /// Deletes whole segments that lie entirely before `cutoff`, returning the
  /// removed URLs. A segment is fully aged out when the *next* segment already
  /// starts at/before `cutoff` (so every event in it predates the cutoff); the
  /// newest segment is never evicted (it is the one still being appended). This
  /// keeps eviction a filename-only `unlink`, never a body read or rewrite.
  @discardableResult
  public static func evict(directory: URL, olderThan cutoff: Instant) throws -> [URL] {
    let segments = segmentURLs(directory: directory)
    guard segments.count > 1 else { return [] }

    var removed: [URL] = []
    for i in 0..<(segments.count - 1) where segments[i + 1].start <= cutoff {
      try FileManager.default.removeItem(at: segments[i].url)
      removed.append(segments[i].url)
    }
    return removed
  }
}
