import EarsCore
import Foundation
import TOMLKit

/// Reads the TOML config file at `path`, if present, and converts it to a
/// `ConfigValue` file layer.
///
/// A missing file is not an error — it means "no file layer", per
/// `docs/configuration.md`'s zero-config guarantee that the suite runs with no
/// config file present. An unreadable or malformed file still throws, so a
/// config file that exists but is broken is never silently ignored.
public func readConfigFileLayer(at path: String) throws -> ConfigValue {
  let expandedPath = (path as NSString).expandingTildeInPath
  guard FileManager.default.fileExists(atPath: expandedPath) else {
    return .table([:])
  }
  let contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
  let table = try TOMLTable(string: contents)
  return TOMLBridge.configValue(from: table)
}
