import Foundation

/// The result of parsing an `index.jsonl` file's contents: the events that
/// parsed cleanly, in chronological order, plus the line numbers of any that
/// didn't.
public struct IndexParseResult: Sendable, Hashable {
  /// Successfully parsed events, sorted by ``IndexEvent/start``.
  public var events: [IndexEvent]
  /// 1-based line numbers of lines that failed to parse as a known event.
  public var malformedLines: [Int]

  public init(events: [IndexEvent], malformedLines: [Int]) {
    self.events = events
    self.malformedLines = malformedLines
  }
}

/// Parses the append-only `index.jsonl` format described in
/// `docs/data-formats.md`: one ``IndexEvent`` per non-blank line.
///
/// The file is append-only and, in the happy path, already ordered by time —
/// but this parser does not assume that. Two defensive behaviours, chosen
/// deliberately over crashing or silently dropping data:
///
/// - **Malformed lines are skipped and noted, not fatal.** A single corrupt or
///   truncated line (e.g. a torn write after a crash) does not prevent the
///   rest of a long-running index from being read. Callers get the line
///   number back in ``IndexParseResult/malformedLines`` so it can be logged.
/// - **Valid events are sorted defensively by ``IndexEvent/start``.** The
///   writer is expected to append in time order, but reconstruction and
///   eviction logic both require chronological input; sorting here means
///   those consumers never have to special-case a rare out-of-order line
///   themselves.
public enum IndexLog {
  public static func parse(_ contents: String) -> IndexParseResult {
    var events: [IndexEvent] = []
    var malformedLines: [Int] = []
    let decoder = JSONDecoder()

    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    for (offset, rawLine) in lines.enumerated() {
      let lineNumber = offset + 1
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }

      guard let data = line.data(using: .utf8),
        let event = try? decoder.decode(IndexEvent.self, from: data)
      else {
        malformedLines.append(lineNumber)
        continue
      }
      events.append(event)
    }

    events.sort { $0.start < $1.start }
    return IndexParseResult(events: events, malformedLines: malformedLines)
  }
}
