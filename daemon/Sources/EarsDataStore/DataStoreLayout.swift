import EarsCore
import Foundation

/// On-disk path layout under a data root, per `docs/data-formats.md`'s
/// "Directory layout" section. Pure `URL` construction only -- no filesystem
/// access happens here, so this is unit-tested without touching disk even
/// though every other type in this module is I/O-heavy.
public enum DataStoreLayout {
  /// `<data-root>/sources/` — the parent of every source directory, enumerated
  /// by the daemon's eviction sweep to find sources with no live actor.
  public static func sourcesRootDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("sources")
  }

  /// `<data-root>/sources/<source-id-path-safe>/`.
  public static func sourceDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourcesRootDirectory(dataRoot: dataRoot).appendingPathComponent(sourceID.pathSafe)
  }

  /// `<data-root>/sources/<source-id-path-safe>/chunks/`, the native-rate
  /// listenable copy.
  public static func chunksDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("chunks")
  }

  /// `<data-root>/sources/<source-id-path-safe>/asr/`, the derived
  /// 16 kHz ASR feed.
  public static func asrDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("asr")
  }

  /// `<data-root>/sources/<source-id-path-safe>/index.jsonl`.
  public static func indexFile(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("index.jsonl")
  }

  /// `<data-root>/sources/<source-id-path-safe>/meta.toml`.
  public static func metaTomlFile(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("meta.toml")
  }

  /// `<data-root>/sessions/`.
  public static func sessionsDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("sessions")
  }

  /// `<data-root>/sessions/<session-id>/`.
  public static func sessionDirectory(dataRoot: URL, sessionID: String) -> URL {
    sessionsDirectory(dataRoot: dataRoot).appendingPathComponent(sessionID)
  }

  /// `<data-root>/sessions/<session-id>/session.toml`.
  public static func sessionTomlFile(dataRoot: URL, sessionID: String) -> URL {
    sessionDirectory(dataRoot: dataRoot, sessionID: sessionID).appendingPathComponent(
      "session.toml")
  }

  /// `<data-root>/meetings/`.
  public static func meetingsDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("meetings")
  }

  /// `<data-root>/meetings/<meeting-id>/`.
  public static func meetingDirectory(dataRoot: URL, meetingID: String) -> URL {
    meetingsDirectory(dataRoot: dataRoot).appendingPathComponent(meetingID)
  }

  /// `<data-root>/meetings/<meeting-id>/meeting.toml`.
  public static func meetingTomlFile(dataRoot: URL, meetingID: String) -> URL {
    meetingDirectory(dataRoot: dataRoot, meetingID: meetingID).appendingPathComponent(
      "meeting.toml")
  }

  /// The `chunks/<filename>` or `asr/<filename>` path recorded in
  /// `index.jsonl`'s `chunk`/`evict` events -- relative to the source
  /// directory, matching the doc's literal examples
  /// (`"file":"chunks/2026-07-17T10-30-00Z.m4a"`).
  public static func relativeChunkPath(subdirectory: ChunkSubdirectory, filename: String) -> String
  {
    "\(subdirectory.rawValue)/\(filename)"
  }
}

/// The two per-chunk feeds a source stores, per `docs/data-formats.md`'s
/// "Dual-rate audio storage" section.
public enum ChunkSubdirectory: String, Sendable, Hashable {
  case chunks
  case asr
}
