import Foundation
import Testing

@testable import EarsCore

/// Covers ``LaunchAgentPlist``: the `earsd` launchd `LaunchAgent` property-list
/// content generator, per `docs/distribution.md`'s "The daemon as a launch agent"
/// and `docs/specs/capture-daemon.md`'s "Lifecycle" sections.
///
/// Assertions parse the generated XML back with `PropertyListSerialization` and
/// check the resulting structure, rather than matching substrings, because plist
/// dictionary key order is unspecified — string-matching would be both fragile
/// (whitespace/ordering) and unable to distinguish "KeepAlive is a dict" from
/// "KeepAlive is a bool" as clearly as a typed structural check does.
@Suite("LaunchAgentPlist")
struct LaunchAgentPlistTests {
  private func parse(_ xml: String) throws -> [String: Any] {
    let data = try #require(xml.data(using: .utf8))
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(object as? [String: Any])
  }

  @Test("produces well-formed XML plist content")
  func producesValidXML() throws {
    let xml = LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd")
    #expect(xml.hasPrefix("<?xml"))
    _ = try parse(xml)
  }

  @Test("labels the agent net.tomelliot.ears.earsd, matching the logging subsystem")
  func label() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    #expect(plist["Label"] as? String == "net.tomelliot.ears.earsd")
    #expect(LaunchAgentPlist.label == "net.tomelliot.ears.earsd")
  }

  @Test("Program reflects the injected executable path")
  func program() throws {
    let plist = try parse(
      LaunchAgentPlist.generate(
        earsdExecutablePath: "/Applications/Ears.app/Contents/MacOS/earsd"))
    #expect(plist["Program"] as? String == "/Applications/Ears.app/Contents/MacOS/earsd")
  }

  @Test("ProgramArguments starts with the injected executable path when no arguments given")
  func programArgumentsNoExtra() throws {
    let plist = try parse(
      LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/ears/bin/earsd"])
  }

  @Test("appends injected arguments after the executable path, in order")
  func programArgumentsWithExtra() throws {
    let plist = try parse(
      LaunchAgentPlist.generate(
        earsdExecutablePath: "/opt/ears/bin/earsd",
        arguments: ["--config", "/opt/ears/config.toml"]))
    #expect(
      plist["ProgramArguments"] as? [String]
        == ["/opt/ears/bin/earsd", "--config", "/opt/ears/config.toml"])
  }

  @Test("RunAtLoad is true, so the agent starts at login")
  func runAtLoad() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    #expect(plist["RunAtLoad"] as? Bool == true)
  }

  @Test("KeepAlive is a dictionary, not a bare bool")
  func keepAliveIsDictionary() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    #expect(plist["KeepAlive"] is [String: Any])
    #expect((plist["KeepAlive"] as? Bool) == nil)
  }

  @Test("KeepAlive restarts on crash but not on a clean exit")
  func keepAliveSuccessfulExit() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
    #expect(keepAlive["SuccessfulExit"] as? Bool == false)
  }

  @Test("KeepAlive throttle interval defaults to 10 seconds")
  func keepAliveDefaultThrottleInterval() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
    #expect(keepAlive["ThrottleInterval"] as? Int == 10)
    #expect(LaunchAgentPlist.defaultThrottleInterval == 10)
  }

  @Test("KeepAlive throttle interval is configurable")
  func keepAliveCustomThrottleInterval() throws {
    let plist = try parse(
      LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd", throttleInterval: 30))
    let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
    #expect(keepAlive["ThrottleInterval"] as? Int == 30)
  }

  @Test("stdout/stderr point at the injected crash log path")
  func injectedCrashLogPath() throws {
    let plist = try parse(
      LaunchAgentPlist.generate(
        earsdExecutablePath: "/opt/ears/bin/earsd",
        crashLogPath: "/tmp/ears-test/earsd-crash.log"))
    #expect(plist["StandardOutPath"] as? String == "/tmp/ears-test/earsd-crash.log")
    #expect(plist["StandardErrorPath"] as? String == "/tmp/ears-test/earsd-crash.log")
  }

  @Test("crash log path defaults to a runtime location distinct from the JSON-Lines log sink")
  func defaultCrashLogPathIsUsedByDefault() throws {
    let plist = try parse(LaunchAgentPlist.generate(earsdExecutablePath: "/opt/ears/bin/earsd"))
    let stdoutPath = try #require(plist["StandardOutPath"] as? String)
    let stderrPath = try #require(plist["StandardErrorPath"] as? String)
    #expect(stdoutPath == LaunchAgentPlist.defaultCrashLogPath)
    #expect(stderrPath == LaunchAgentPlist.defaultCrashLogPath)
    #expect(!stdoutPath.hasSuffix(".jsonl"))
  }
}
