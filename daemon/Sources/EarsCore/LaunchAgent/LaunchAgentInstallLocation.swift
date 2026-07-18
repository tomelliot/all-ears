/// The conventional per-user install location for the `earsd` `LaunchAgent`
/// property list, per `docs/distribution.md`'s "The daemon as a launch agent":
/// `~/Library/LaunchAgents/net.tomelliot.ears.earsd.plist`.
///
/// Purely informational — this does not write the file or register it with
/// `SMAppService`/`launchctl`; that's a later Phase 1 task or a manual install
/// step.
public enum LaunchAgentInstallLocation {
  /// - Parameter homeDirectory: The user's home directory. Taken as a parameter
  ///   rather than read from the environment (`NSHomeDirectory()`), so this stays
  ///   a pure, injectable function — matching how `EarsConfig`'s
  ///   `expandConfigPaths` takes `homeDirectory` as a parameter rather than
  ///   reading it directly.
  public static func path(homeDirectory: String) -> String {
    let base = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
    return "\(base)/Library/LaunchAgents/\(LaunchAgentPlist.label).plist"
  }
}
