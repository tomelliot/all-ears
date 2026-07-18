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

  /// The full current contents of the index file, or an empty string if it
  /// doesn't exist yet. A thin read-side convenience so callers (startup
  /// gap detection) don't need their own file-existence dance before
  /// handing contents to ``IndexLog/parse(_:)``.
  public func readContents() throws -> String {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return ""
    }
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
