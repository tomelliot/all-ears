import EarsCore
import Foundation

/// Appends ``IndexEvent`` lines to a source's `index.jsonl`, per
/// `docs/data-formats.md`'s "The index" section: "Append-only JSON Lines,
/// one event per line... Because it is append-only, `tail -f index.jsonl`
/// shows live capture."
///
/// This reuses ``IndexEvent``'s own `Codable` conformance for the JSON
/// shape -- this type only owns the append-mode file I/O (open, seek to
/// end, write one line + newline, flush) and creating the file/parent
/// directory the first time a source writes.
///
/// An `actor` because several callers within a source's `CaptureActor`
/// (chunk finalization, eviction, startup gap detection) append to the same
/// file, and interleaved writes from concurrent, un-serialized callers
/// would corrupt line boundaries. One `IndexAppender` is shared per source.
public actor IndexAppender {
  private let fileURL: URL
  private let encoder: JSONEncoder

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
  }

  /// Appends `event` as one JSON line, creating the file (and its parent
  /// directory) if this is the first write. Flushes before returning, so a
  /// concurrent `tail -f` (or a crash immediately after) always sees a
  /// complete line.
  public func append(_ event: IndexEvent) throws {
    var line = try encoder.encode(event)
    line.append(UInt8(ascii: "\n"))

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
        throw DataStoreIOError.fsyncFailed(path: fileURL.path, errno: 0)
      }
    }

    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try handle.synchronize()
  }

  /// The latest `end` instant across all coverage events in the index
  /// (`chunk`/`vad`/`gap`; `evict` is excluded), or `nil` if the file
  /// doesn't exist or has no coverage events.
  ///
  /// This is the read-side counterpart of ``StartupGapDetector/lastKnownEnd(in:)``,
  /// but avoids reading and parsing the whole `index.jsonl` on startup:
  /// the index is append-only and almost always time-ordered, so the
  /// maximum `end` lives at the tail. We read backward from EOF in
  /// fixed-size chunks, parse only the trailing lines, and return as soon
  /// as a coverage event is found. O(1) for the common case; degrades to a
  /// full read only if the tail is exclusively `evict` events (rare).
  ///
  /// Before this method, ``StartupGapAppender`` read the entire file via
  /// ``readContents()`` and parsed every line — fine for a fresh source,
  /// but a multi-day run accumulates a multi-megabyte index that blocked
  /// `CaptureActor.start()` for seconds on every daemon restart, leaving
  /// the source stuck in `.disabled` and the control plane unreachable.
  public func lastKnownEnd() throws -> Instant? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    let fileSize = try handle.seekToEnd()
    guard fileSize > 0 else { return nil }

    let chunkSize: UInt64 = 65_536  // 64 KB ≈ ~600 lines of index events
    var offset = fileSize
    var maxEnd: Instant? = nil

    while offset > 0 {
      let readSize = min(chunkSize, offset)
      offset -= readSize
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: Int(readSize)) ?? Data()
      guard let block = String(data: data, encoding: .utf8) else { break }

      // Every line in the block. A backward read may begin mid-record (a
      // partial line split at the block boundary); such a fragment fails
      // to decode and is skipped by the `try?` below, so no special handling
      // is needed — and dropping the first line wholesale would wrongly
      // skip a complete line when the boundary lands on a newline.
      let lines = block.split(separator: "\n", omittingEmptySubsequences: true)

      let decoder = JSONDecoder()
      var foundCoverageInBlock = false
      for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces)
        guard !line.isEmpty,
          let lineData = line.data(using: .utf8),
          let event = try? decoder.decode(IndexEvent.self, from: lineData)
        else { continue }
        switch event {
        case .chunk(_, let end, _, _):
          if maxEnd == nil || end > maxEnd! { maxEnd = end }
          foundCoverageInBlock = true
        case .vad(_, _, let end):
          if maxEnd == nil || end > maxEnd! { maxEnd = end }
          foundCoverageInBlock = true
        case .gap(_, let end, _):
          if maxEnd == nil || end > maxEnd! { maxEnd = end }
          foundCoverageInBlock = true
        case .evict:
          continue
        }
      }

      // The tail's coverage events are the latest written; once we've seen
      // at least one coverage event in the most recent block(s), no earlier
      // block can exceed it (append-only, time-ordered). Only keep scanning
      // backward when this block had zero coverage events (all evicts).
      if foundCoverageInBlock { return maxEnd }
    }
    return maxEnd
  }

  /// The full current contents of the index file, or an empty string if it
  /// doesn't exist yet. A thin read-side convenience for tests and for
  /// callers that genuinely need the whole index (not startup gap
  /// detection — use ``lastKnownEnd()`` for that).
  public func readContents() throws -> String {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return ""
    }
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
