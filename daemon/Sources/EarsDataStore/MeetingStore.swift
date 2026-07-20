import EarsConfig
import EarsCore
import Foundation

/// Reads and writes a meeting's `meeting.toml` (schema 2), per the
/// `meetings/<meeting-id>/meeting.toml` layout — the meeting sibling of
/// ``SessionStore``, and thin file I/O only in exactly the same way: the
/// field mapping is `MeetingDescriptorTOML` (`EarsConfig`), the serialization
/// is `printableConfig(_:)`/`readConfigFileLayer(at:)`. Written atomically on
/// every mutation so a crash never leaves a torn descriptor.
public enum MeetingStore {
  /// Writes `meeting` to `<data-root>/meetings/<meeting-id>/meeting.toml`,
  /// creating the meeting directory if it doesn't exist yet.
  public static func write(_ meeting: Meeting, dataRoot: URL) throws {
    let url = DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: meeting.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(MeetingDescriptorTOML.encode(meeting))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/meetings/<meeting-id>/meeting.toml`.
  ///
  /// - Throws: ``DataStoreError/meetingNotFound(_:)`` if the file doesn't
  ///   exist; ``DescriptorTOMLError`` if it exists but doesn't parse into a
  ///   valid ``Meeting`` (an unknown schema included).
  public static func read(meetingID: String, dataRoot: URL) throws -> Meeting {
    let url = DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: meetingID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DataStoreError.meetingNotFound(meetingID)
    }
    let value = try readConfigFileLayer(at: url.path)
    return try MeetingDescriptorTOML.decode(value)
  }

  /// Reads every parseable `meetings/*/meeting.toml` under `dataRoot` — the
  /// startup scan `MeetingRegistry` rebuilds its state from, and what
  /// `ears meeting list --all` reads daemon-free. A missing `meetings/`
  /// directory is an empty list, and an unparseable descriptor is skipped
  /// and reported via `onSkip` rather than failing the whole scan.
  public static func readAll(
    dataRoot: URL, onSkip: (String, Error) -> Void = { _, _ in }
  ) -> [Meeting] {
    let directory = DataStoreLayout.meetingsDirectory(dataRoot: dataRoot)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    var meetings: [Meeting] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let meetingID = entry.lastPathComponent
      do {
        meetings.append(try read(meetingID: meetingID, dataRoot: dataRoot))
      } catch DataStoreError.meetingNotFound {
        continue  // a stray non-meeting entry under meetings/ — not an error
      } catch {
        onSkip(meetingID, error)
      }
    }
    return meetings
  }
}

/// Appends domain events to a meeting's `meetings/<uuid>/events.jsonl` — the
/// durable per-meeting timeline (who was present during minutes 10–20, when
/// pauses happened, what the meeting used to be called). Written for disk
/// consumers (`summarize`, humans, `jq`), **not** used for protocol sync;
/// mirrors the `index.jsonl` append-only idiom.
public enum MeetingEventLog {
  /// One `events.jsonl` line. `event` is one of `started`,
  /// `interval_opened`, `interval_closed`, `attendee_joined`,
  /// `attendee_left`, `renamed`, `ended`; the optional fields carry the
  /// event's own detail.
  public struct Entry: Sendable, Hashable, Codable {
    public var t: String
    public var event: String
    /// `attendee_joined`/`attendee_left`: the attendee id.
    public var attendee: String?
    /// `renamed`: the new title.
    public var title: String?
    /// `ended`: `"client"` for an explicit `meeting.end`, `"ingest-idle"`
    /// for the orphan grace timer.
    public var reason: String?

    public init(
      t: String, event: String, attendee: String? = nil, title: String? = nil,
      reason: String? = nil
    ) {
      self.t = t
      self.event = event
      self.attendee = attendee
      self.title = title
      self.reason = reason
    }
  }

  /// `<data-root>/meetings/<meeting-id>/events.jsonl`.
  public static func fileURL(dataRoot: URL, meetingID: String) -> URL {
    DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID)
      .appendingPathComponent("events.jsonl")
  }

  /// Appends one entry (creating the file and directory as needed). Failures
  /// throw — callers decide whether the timeline is best-effort.
  public static func append(
    _ entry: Entry, dataRoot: URL, meetingID: String
  ) throws {
    let url = fileURL(dataRoot: dataRoot, meetingID: meetingID)
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
  public static func readAll(dataRoot: URL, meetingID: String) -> [Entry] {
    let url = fileURL(dataRoot: dataRoot, meetingID: meetingID)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
      try? decoder.decode(Entry.self, from: Data(line.utf8))
    }
  }
}
