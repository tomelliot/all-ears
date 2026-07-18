import EarsConfig
import EarsCore
import Foundation

/// Reads and writes a source's `meta.toml`, per `docs/data-formats.md`'s
/// `sources/<source-id>/meta.toml` layout.
///
/// Thin file I/O only: the field-by-field TOML content mapping is
/// ``SourceDescriptorTOML`` (`EarsConfig`, Wave 2), and the text
/// serialization is `EarsConfig`'s ``printableConfig(_:)``/``readConfigFileLayer(at:)``
/// -- this type's job is turning that content into bytes on disk (and back)
/// at the right path, creating the source directory as needed.
public enum SourceMetaStore {
  /// Writes `descriptor` to `<data-root>/sources/<source-id>/meta.toml`,
  /// creating the source directory if it doesn't exist yet.
  public static func write(_ descriptor: SourceDescriptor, dataRoot: URL) throws {
    let url = DataStoreLayout.metaTomlFile(dataRoot: dataRoot, sourceID: descriptor.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(SourceDescriptorTOML.encode(descriptor))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/sources/<source-id>/meta.toml`.
  ///
  /// - Throws: ``DataStoreError/sourceMetaNotFound(_:)`` if the file
  ///   doesn't exist; ``DescriptorTOMLError`` if it exists but doesn't
  ///   parse into a valid ``SourceDescriptor``.
  public static func read(sourceID: SourceID, dataRoot: URL) throws -> SourceDescriptor {
    let url = DataStoreLayout.metaTomlFile(dataRoot: dataRoot, sourceID: sourceID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DataStoreError.sourceMetaNotFound(sourceID)
    }
    let value = try readConfigFileLayer(at: url.path)
    return try SourceDescriptorTOML.decode(value)
  }
}
