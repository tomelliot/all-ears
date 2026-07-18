import EarsConfig
import EarsCore
import Foundation

/// Reads and writes a session's `session.toml`, per `docs/data-formats.md`'s
/// `sessions/<session-id>/session.toml` layout.
///
/// Thin file I/O only: the field-by-field TOML content mapping is
/// ``SessionDescriptorTOML`` (`EarsConfig`, Wave 2), and the text
/// serialization is `EarsConfig`'s ``printableConfig(_:)``/``readConfigFileLayer(at:)``
/// -- this type's job is turning that content into bytes on disk (and back)
/// at the right path, creating the session directory as needed.
public enum SessionStore {
  /// Writes `descriptor` to `<data-root>/sessions/<session-id>/session.toml`,
  /// creating the session directory if it doesn't exist yet.
  public static func write(_ descriptor: SessionDescriptor, dataRoot: URL) throws {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: descriptor.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(SessionDescriptorTOML.encode(descriptor))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/sessions/<session-id>/session.toml`.
  ///
  /// - Throws: ``DataStoreError/sessionNotFound(_:)`` if the file doesn't
  ///   exist; ``DescriptorTOMLError`` if it exists but doesn't parse into a
  ///   valid ``SessionDescriptor``.
  public static func read(sessionID: String, dataRoot: URL) throws -> SessionDescriptor {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: sessionID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DataStoreError.sessionNotFound(sessionID)
    }
    let value = try readConfigFileLayer(at: url.path)
    return try SessionDescriptorTOML.decode(value)
  }
}
