import EarsConfig
import EarsCore
import Foundation

/// Reads and writes a meeting's `meeting.toml`, per the
/// `meetings/<meeting-id>/meeting.toml` layout — the meeting-identity sibling
/// of ``SessionStore``, and thin file I/O only in exactly the same way: the
/// field mapping is `MeetingDescriptorTOML` (`EarsConfig`), the serialization
/// is `printableConfig(_:)`/`readConfigFileLayer(at:)`.
public enum MeetingStore {
  /// Writes `descriptor` to `<data-root>/meetings/<meeting-id>/meeting.toml`,
  /// creating the meeting directory if it doesn't exist yet.
  public static func write(_ descriptor: MeetingDescriptor, dataRoot: URL) throws {
    let url = DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: descriptor.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(MeetingDescriptorTOML.encode(descriptor))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/meetings/<meeting-id>/meeting.toml`.
  ///
  /// - Throws: ``DataStoreError/meetingNotFound(_:)`` if the file doesn't
  ///   exist; ``DescriptorTOMLError`` if it exists but doesn't parse into a
  ///   valid ``MeetingDescriptor``.
  public static func read(meetingID: String, dataRoot: URL) throws -> MeetingDescriptor {
    let url = DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: meetingID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DataStoreError.meetingNotFound(meetingID)
    }
    let value = try readConfigFileLayer(at: url.path)
    return try MeetingDescriptorTOML.decode(value)
  }

  /// Reads every parseable `meetings/*/meeting.toml` under `dataRoot` — the
  /// startup scan `MeetingRegistry` builds its `(platform, external_id)`
  /// lookup from. A missing `meetings/` directory is an empty list, and an
  /// unparseable descriptor is skipped and reported via `onSkip` rather than
  /// failing the whole scan (one corrupt file must not break rejoin
  /// correlation for every other meeting).
  public static func readAll(
    dataRoot: URL, onSkip: (String, Error) -> Void = { _, _ in }
  ) -> [MeetingDescriptor] {
    let directory = DataStoreLayout.meetingsDirectory(dataRoot: dataRoot)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    var descriptors: [MeetingDescriptor] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let meetingID = entry.lastPathComponent
      do {
        descriptors.append(try read(meetingID: meetingID, dataRoot: dataRoot))
      } catch DataStoreError.meetingNotFound {
        continue  // a stray non-meeting entry under meetings/ — not an error
      } catch {
        onSkip(meetingID, error)
      }
    }
    return descriptors
  }
}
