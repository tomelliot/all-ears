import EarsConfig
import EarsCore
import Foundation
import Synchronization

/// Reads and writes a session's `session.toml` (schema 3), per the
/// `sessions/<session-id>/session.toml` layout — thin file I/O only: the
/// field mapping is `SessionDescriptorTOML` (`EarsConfig`), the serialization
/// is `printableConfig(_:)`/`readConfigFileLayer(at:)`. Written atomically on
/// every mutation so a crash never leaves a torn descriptor.
public enum SessionStore {
  /// Writes `session` to `<data-root>/sessions/<session-id>/session.toml`,
  /// creating the session directory if it doesn't exist yet. Drops the
  /// session from `cache`, so the writer's own next read is always fresh.
  public static func write(_ session: Session, dataRoot: URL, cache: Cache? = nil) throws {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: session.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(SessionDescriptorTOML.encode(session))
    defer { cache?.invalidate(sessionID: session.id) }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/sessions/<session-id>/session.toml`.
  ///
  /// - Throws: ``DataStoreError/sessionNotFound(_:)`` if the file doesn't
  ///   exist; ``DescriptorTOMLError`` if it exists but doesn't parse into a
  ///   valid ``Session`` (an unknown schema included).
  ///
  /// With a `cache`, an unchanged file returns its earlier result (the
  /// decoded session or the parse error) without parsing it again.
  public static func read(
    sessionID: String, dataRoot: URL, cache: Cache? = nil
  ) throws -> Session {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: sessionID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      cache?.invalidate(sessionID: sessionID)
      throw DataStoreError.sessionNotFound(sessionID)
    }
    guard let cache else { return try parse(url) }
    return try cache.session(sessionID: sessionID, url: url, parse: parse)
  }

  private static func parse(_ url: URL) throws -> Session {
    let value = try readConfigFileLayer(at: url.path)
    return try SessionDescriptorTOML.decode(value)
  }

  /// Reads every parseable `sessions/*/session.toml` under `dataRoot` — the
  /// startup scan `SessionRegistry` rebuilds its state from, and what
  /// `ears session list --all` reads daemon-free. A missing `sessions/`
  /// directory is an empty list, and an unparseable descriptor is skipped
  /// and reported via `onSkip` rather than failing the whole scan.
  ///
  /// `cache` is for the long-running daemon's repeated scans (see ``Cache``);
  /// sessions no longer on disk drop out of it.
  public static func readAll(
    dataRoot: URL, cache: Cache? = nil, onSkip: (String, Error) -> Void = { _, _ in }
  ) -> [Session] {
    let directory = DataStoreLayout.sessionsDirectory(dataRoot: dataRoot)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else {
      cache?.retain(sessionIDs: [])
      return []
    }
    var sessions: [Session] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let sessionID = entry.lastPathComponent
      do {
        sessions.append(try read(sessionID: sessionID, dataRoot: dataRoot, cache: cache))
      } catch DataStoreError.sessionNotFound {
        continue  // a stray non-session entry under sessions/ — not an error
      } catch {
        onSkip(sessionID, error)
      }
    }
    cache?.retain(sessionIDs: Set(entries.map(\.lastPathComponent)))
    return sessions
  }

  /// Decoded `session.toml` results keyed by session id, for a process that
  /// reads the same descriptors over and over (`earsd`'s retention sweep).
  ///
  /// Each parse through TOMLKit 0.6.0 leaks the whole parsed document — its
  /// `TOMLTable` never frees the C++ table — so a once-a-minute rescan of
  /// every session grows the daemon by gigabytes a day. The cache parses a
  /// file again only when its modification date, size, or file number
  /// changes. The file number catches an atomic rewrite (a new inode) that a
  /// coarse modification date and an equal size would miss. The short-lived
  /// CLIs pass no cache: they exit, so their leak is bounded.
  public final class Cache: Sendable {
    private struct Stamp: Hashable {
      var modified: Date?
      var size: Int?
      var fileNumber: Int?
    }

    private struct Entry {
      var stamp: Stamp
      var result: Result<Session, any Error>
    }

    private struct State {
      var entries: [String: Entry] = [:]
      var parseCount = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// How many times this cache has parsed a file — the seam tests assert
    /// "not parsed again" through.
    public var parseCount: Int { state.withLock { $0.parseCount } }

    /// Forgets `sessionID`, so its next read parses the file.
    public func invalidate(sessionID: String) {
      _ = state.withLock { $0.entries.removeValue(forKey: sessionID) }
    }

    /// Forgets every session not in `sessionIDs`.
    func retain(sessionIDs: Set<String>) {
      state.withLock { state in
        state.entries = state.entries.filter { sessionIDs.contains($0.key) }
      }
    }

    func session(
      sessionID: String, url: URL, parse: (URL) throws -> Session
    ) throws -> Session {
      let stamp = Self.stamp(of: url)
      if let stamp,
        let entry = state.withLock({ $0.entries[sessionID] }),
        entry.stamp == stamp
      {
        return try entry.result.get()
      }
      // Parsed outside the lock: concurrent readers of other sessions never
      // wait on this file's I/O.
      let result = Result { try parse(url) }
      state.withLock { state in
        state.parseCount += 1
        if let stamp {
          state.entries[sessionID] = Entry(stamp: stamp, result: result)
        } else {
          state.entries.removeValue(forKey: sessionID)
        }
      }
      return try result.get()
    }

    private static func stamp(of url: URL) -> Stamp? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      else { return nil }
      return Stamp(
        modified: attributes[.modificationDate] as? Date,
        size: (attributes[.size] as? NSNumber)?.intValue,
        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }
  }
}

/// Appends domain events to a session's `sessions/<uuid>/events.jsonl` — the
/// durable per-session timeline (who was present during minutes 10–20, when
/// pauses happened, what the session used to be called). Written for disk
/// consumers (`summarize`, humans, `jq`), **not** used for protocol sync;
/// mirrors the `index.jsonl` append-only idiom.
public enum SessionEventLog {
  /// One `events.jsonl` line. `event` is one of `started`,
  /// `interval_opened`, `interval_closed`, `attendee_joined`,
  /// `attendee_left`, `renamed`, `capture_failed`, `ended`; the optional
  /// fields carry the event's own detail.
  public struct Entry: Sendable, Hashable, Codable {
    public var t: String
    public var event: String
    /// `attendee_joined`/`attendee_left`: the attendee id.
    public var attendee: String?
    /// `renamed`: the new title.
    public var title: String?
    /// `capture_failed`: the source whose capture died mid-call.
    public var source: String?
    /// `ended`: `"client"` for an explicit `session.end`, `"ingest-idle"`
    /// for the orphan grace timer. `capture_failed`: the capture client's
    /// stated cause.
    public var reason: String?

    public init(
      t: String, event: String, attendee: String? = nil, title: String? = nil,
      source: String? = nil, reason: String? = nil
    ) {
      self.t = t
      self.event = event
      self.attendee = attendee
      self.title = title
      self.source = source
      self.reason = reason
    }
  }

  /// `<data-root>/sessions/<session-id>/events.jsonl`.
  public static func fileURL(dataRoot: URL, sessionID: String) -> URL {
    DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("events.jsonl")
  }

  /// Appends one entry (creating the file and directory as needed). Failures
  /// throw — callers decide whether the timeline is best-effort.
  public static func append(
    _ entry: Entry, dataRoot: URL, sessionID: String
  ) throws {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var line = try encoder.encode(entry)
    line.append(0x0A)
    if let handle = FileHandle(forWritingAtPath: url.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: url)
    }
  }

  /// Reads every parseable entry, in file order — for tests and disk
  /// consumers; unparseable lines are skipped.
  public static func readAll(dataRoot: URL, sessionID: String) -> [Entry] {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
      try? decoder.decode(Entry.self, from: Data(line.utf8))
    }
  }
}

/// Appends the browser's attribution flight-recorder events to a session's
/// `sessions/<uuid>/attribution.jsonl`, beside `events.jsonl` — same
/// append-only JSONL discipline, and like `events.jsonl` it survives audio
/// retention (only `sources/` is ever deleted).
///
/// Unlike ``SessionEventLog`` the daemon does not own the vocabulary: each
/// line arrives pre-encoded from the extension (`browser/lib/attribution-log.ts`,
/// schema-versioned per line) and is written **verbatim**, so what lands on
/// disk is byte-for-byte what the browser recorded. The only gate is framing:
/// a line must parse as a single JSON object with no embedded newline, or the
/// JSONL file itself would be corrupted for every later reader.
public enum SessionAttributionLog {
  /// `<data-root>/sessions/<session-id>/attribution.jsonl`.
  public static func fileURL(dataRoot: URL, sessionID: String) -> URL {
    DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("attribution.jsonl")
  }

  /// Appends `lines` (creating the file and directory as needed), skipping
  /// any that would break the JSONL framing. Returns how many were written.
  /// Failures throw — callers decide whether the log is best-effort.
  @discardableResult
  public static func append(
    lines: [String], dataRoot: URL, sessionID: String
  ) throws -> Int {
    let valid = lines.filter(isValidLine)
    guard !valid.isEmpty else { return 0 }
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = Data((valid.joined(separator: "\n") + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: url.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: payload)
    } else {
      try payload.write(to: url)
    }
    return valid.count
  }

  /// Every line, in file order, verbatim — for tests and offline replay.
  public static func readAllLines(dataRoot: URL, sessionID: String) -> [String] {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  /// One JSON object, no embedded newline — the framing contract above.
  private static func isValidLine(_ line: String) -> Bool {
    guard !line.contains("\n"), !line.contains("\r") else { return false }
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
      return false
    }
    return object is [String: Any]
  }
}
