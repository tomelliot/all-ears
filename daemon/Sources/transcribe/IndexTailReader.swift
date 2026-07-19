import EarsCore
import Foundation

/// Tails a source's append-only `index.jsonl` by byte offset for `--follow`:
/// each ``readNewEvents(onMalformed:)`` call reads only the bytes appended
/// since the last call (never re-reading or re-parsing the whole file, per
/// the follow spec's "track a read offset" requirement) and decodes the
/// complete lines among them.
///
/// A trailing partial line — the writer (`IndexAppender`) appends whole
/// lines, but a read can still race the underlying write syscall — is
/// retained by the shared ``LineFramer`` (the same byte-framing state
/// machine the control socket uses) and completed by a later call, so a
/// torn read never mis-parses. Malformed complete lines are reported and
/// skipped, matching ``IndexLog``'s tolerance; unlike `IndexLog.parse`,
/// events are returned in *append order* (a live tail wants arrival order,
/// and the writer already appends chronologically).
struct IndexTailReader {
  private let fileURL: URL
  private var offset: UInt64
  private var framer = LineFramer()
  private let decoder = JSONDecoder()

  /// - Parameters:
  ///   - fileURL: The `index.jsonl` to tail; it may not exist yet (a source
  ///     that has never finalized a chunk), in which case reads return
  ///     nothing until it appears.
  ///   - startAtEnd: When `true` (the follow attach semantics: "a subscriber
  ///     that connects late gets no replay"), events already on disk at
  ///     construction are skipped and only lines appended afterwards are
  ///     returned.
  init(fileURL: URL, startAtEnd: Bool) {
    self.fileURL = fileURL
    if startAtEnd,
      let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    {
      self.offset = size
    } else {
      self.offset = 0
    }
  }

  /// Reads and decodes every complete line appended since the last call, in
  /// append order. `onMalformed` receives the raw text of any complete line
  /// that failed to decode as an ``IndexEvent``.
  mutating func readNewEvents(onMalformed: (String) -> Void) -> [IndexEvent] {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: offset)) != nil,
      let data = try? handle.readToEnd(),
      !data.isEmpty
    else { return [] }
    offset += UInt64(data.count)

    var events: [IndexEvent] = []
    for lineBytes in framer.append(Array(data)) {
      let trimmed = String(decoding: lineBytes, as: UTF8.self)
        .trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if let event = try? decoder.decode(IndexEvent.self, from: Data(lineBytes)) {
        events.append(event)
      } else {
        onMalformed(trimmed)
      }
    }
    return events
  }
}
