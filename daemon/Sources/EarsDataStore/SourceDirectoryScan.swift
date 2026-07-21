import EarsConfig
import EarsCore
import Foundation

/// Enumerates the sources present *on disk* under `<data-root>/sources/`,
/// independent of which sources currently have a live `CaptureActor`.
///
/// The daemon's eviction sweep drives from this rather than its in-memory actor
/// set, so it reaches sources with no running actor — an ended browser meeting
/// whose `browser:<label>` actor was never rebuilt after a restart, a disabled
/// config source, anything left on disk past its time cap. Every source the
/// daemon has ever built persists a `meta.toml` (`buildCaptureActor` →
/// `writeSourceMeta`), so a `meta.toml` on disk is the authority on what exists.
public enum SourceDirectoryScan {
  /// One entry per source directory with a readable `meta.toml`. Directories
  /// without one (partially created, or not a source at all) are skipped; a
  /// `meta.toml` that fails to parse is skipped too, so one corrupt source
  /// never blocks the sweep from evicting the rest.
  public static func sources(dataRoot: URL) -> [(descriptor: SourceDescriptor, directory: URL)] {
    let root = DataStoreLayout.sourcesRootDirectory(dataRoot: dataRoot)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }

    var result: [(descriptor: SourceDescriptor, directory: URL)] = []
    for directory in entries {
      let metaURL = directory.appendingPathComponent("meta.toml")
      guard
        FileManager.default.fileExists(atPath: metaURL.path),
        let value = try? readConfigFileLayer(at: metaURL.path),
        let descriptor = try? SourceDescriptorTOML.decode(value)
      else { continue }
      result.append((descriptor, directory))
    }
    return result
  }
}
