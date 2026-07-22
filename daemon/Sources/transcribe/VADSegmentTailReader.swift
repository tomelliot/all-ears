import EarsCore
import EarsDataStore
import Foundation

/// Tails a source's segmented VAD stream (`vad/<timestamp>.jsonl`) for
/// `--follow`, the segment-aware counterpart to ``IndexTailReader``: it byte-tails
/// the segment currently being written and, when the writer rolls over to a new
/// segment (``VADSegmentWriter``), advances through the newer segments in order,
/// reading each from its start. Old segments are append-only and complete once a
/// newer one exists, so rolling forward never re-reads or races a write.
struct VADSegmentTailReader {
  private let directory: URL
  private var inner: IndexTailReader?
  private var currentStart: Instant?

  /// - Parameters:
  ///   - directory: The source's `vad/` directory.
  ///   - startAtEnd: When `true`, skip everything present at construction and
  ///     read only what is appended afterwards (matching ``IndexTailReader``): a
  ///     late follower gets no replay. The attach point is fixed here, at init —
  ///     the newest segment's current end — so a segment that appears *later* is
  ///     read in full from its start, never skipped.
  init(directory: URL, startAtEnd: Bool) {
    self.directory = directory
    if let newest = VADSegmentStore.segmentURLs(directory: directory).last {
      self.inner = IndexTailReader(fileURL: newest.url, startAtEnd: startAtEnd)
      self.currentStart = newest.start
    }
    // No segment yet: `inner` stays nil, and the first segment to appear — all
    // of it written after this init — is read from its start below.
  }

  /// Every VAD event appended since the last call, in append order across
  /// segment boundaries. `onMalformed` receives any complete line that failed to
  /// decode, matching ``IndexTailReader``.
  mutating func readNewEvents(onMalformed: (String) -> Void) -> [IndexEvent] {
    let segments = VADSegmentStore.segmentURLs(directory: directory)
    guard !segments.isEmpty else { return [] }

    if inner == nil {
      // Nothing existed at init; the oldest segment now present is entirely new.
      inner = IndexTailReader(fileURL: segments[0].url, startAtEnd: false)
      currentStart = segments[0].start
    }

    var events: [IndexEvent] = []
    while true {
      events.append(contentsOf: inner!.readNewEvents(onMalformed: onMalformed))
      guard let current = currentStart,
        let next = segments.first(where: { $0.start > current })
      else { break }
      inner = IndexTailReader(fileURL: next.url, startAtEnd: false)
      currentStart = next.start
    }
    return events
  }
}
