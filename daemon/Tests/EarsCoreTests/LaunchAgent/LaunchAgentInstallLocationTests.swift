import Testing

@testable import EarsCore

/// Covers ``LaunchAgentInstallLocation``: the conventional per-user install path
/// for the `earsd` `LaunchAgent` plist, per `docs/distribution.md`'s "The daemon
/// as a launch agent" — purely informational, no filesystem access.
@Suite("LaunchAgentInstallLocation")
struct LaunchAgentInstallLocationTests {
  @Test("resolves the conventional per-user LaunchAgent path")
  func conventionalPath() {
    let path = LaunchAgentInstallLocation.path(homeDirectory: "/Users/tom")
    #expect(path == "/Users/tom/Library/LaunchAgents/net.tomelliot.ears.earsd.plist")
  }

  @Test("tolerates a trailing slash on the home directory without doubling it")
  func trailingSlash() {
    let path = LaunchAgentInstallLocation.path(homeDirectory: "/Users/tom/")
    #expect(path == "/Users/tom/Library/LaunchAgents/net.tomelliot.ears.earsd.plist")
  }

  @Test("names the file after the LaunchAgentPlist label")
  func usesLabel() {
    let path = LaunchAgentInstallLocation.path(homeDirectory: "/Users/x")
    #expect(path.hasSuffix("/\(LaunchAgentPlist.label).plist"))
  }
}
