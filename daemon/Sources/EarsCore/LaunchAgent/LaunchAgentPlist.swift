import Foundation

/// Generates the XML property-list **content** for the `earsd` launchd
/// `LaunchAgent`, per `docs/distribution.md`'s "The daemon as a launch agent"
/// and `docs/specs/capture-daemon.md`'s "Lifecycle" sections.
///
/// This produces a `String` ready to write to a `.plist` file — writing it to
/// disk and registering it (`SMAppService`, `launchctl`) are out of scope here;
/// that's a later Phase 1 task or a manual install step. No file I/O happens in
/// this type.
public enum LaunchAgentPlist {
  /// The launchd label for the `earsd` agent, matching the `net.tomelliot.ears`
  /// unified-logging subsystem used elsewhere (`docs/logging.md`).
  public static let label = "net.tomelliot.ears.earsd"

  /// Default `KeepAlive.ThrottleInterval` in seconds: how long launchd waits
  /// between restarts after a crash, so a crash-loop doesn't spin tightly.
  public static let defaultThrottleInterval = 10

  /// Default `StandardOutPath`/`StandardErrorPath`: a small pre-logger-init
  /// crash log under the per-user data root's `runtime/` directory (the same
  /// directory convention `docs/configuration.md` uses for `socket_path`),
  /// distinct from the JSON-Lines sink `EarsLogging` writes to `<data-root>/logs/`
  /// once the daemon's own logger is initialized. launchd needs somewhere to
  /// capture output from before that logger exists, or if the process fails to
  /// start at all.
  ///
  /// Expressed with a literal, unexpanded `~`, matching how
  /// `docs/configuration.md` documents its own `data_root` default — `EarsCore`
  /// does not read the real home directory (see ``LaunchAgentInstallLocation``,
  /// which takes it as a parameter instead). Callers with a resolved data root
  /// or home directory should pass an already-expanded `crashLogPath`.
  public static let defaultCrashLogPath =
    "~/Library/Application Support/ears/runtime/earsd-crash.log"

  /// Builds the XML property-list content for the `earsd` `LaunchAgent`.
  ///
  /// - Parameters:
  ///   - earsdExecutablePath: Path to the `earsd` binary. Injected rather than
  ///     hardcoded, since the real install path depends on app-bundle packaging
  ///     that doesn't exist yet (`docs/distribution.md`'s signing/notarization
  ///     work, a later phase).
  ///   - arguments: Extra arguments launched after `earsdExecutablePath` in
  ///     `ProgramArguments`. Defaults to none.
  ///   - throttleInterval: Seconds launchd waits between restarts after a crash
  ///     (`KeepAlive.ThrottleInterval`). Defaults to ``defaultThrottleInterval``.
  ///   - crashLogPath: Where launchd redirects stdout/stderr
  ///     (`StandardOutPath`/`StandardErrorPath`). Defaults to
  ///     ``defaultCrashLogPath``.
  /// - Returns: XML property-list content, ready to write to a `.plist` file.
  public static func generate(
    earsdExecutablePath: String,
    arguments: [String] = [],
    throttleInterval: Int = defaultThrottleInterval,
    crashLogPath: String = defaultCrashLogPath
  ) -> String {
    let document = Document(
      label: label,
      program: earsdExecutablePath,
      programArguments: [earsdExecutablePath] + arguments,
      runAtLoad: true,
      keepAlive: Document.KeepAlivePolicy(
        successfulExit: false,
        throttleInterval: throttleInterval
      ),
      standardOutPath: crashLogPath,
      standardErrorPath: crashLogPath
    )

    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    // `Document` encodes only Strings/Bools/Ints/arrays of those — this cannot
    // fail for any input `generate` accepts.
    let data = try! encoder.encode(document)
    return String(data: data, encoding: .utf8)!
  }

  /// Typed shape of the generated plist, encoded via `PropertyListEncoder`
  /// rather than hand-built `[String: Any]` so the field types (a `KeepAlive`
  /// *dictionary*, not a bare bool; `RunAtLoad` a bool; `ThrottleInterval` an
  /// int) are enforced by the compiler rather than by construction discipline.
  private struct Document: Encodable, Sendable {
    struct KeepAlivePolicy: Encodable, Sendable {
      let successfulExit: Bool
      let throttleInterval: Int

      enum CodingKeys: String, CodingKey {
        case successfulExit = "SuccessfulExit"
        case throttleInterval = "ThrottleInterval"
      }
    }

    let label: String
    let program: String
    let programArguments: [String]
    let runAtLoad: Bool
    let keepAlive: KeepAlivePolicy
    let standardOutPath: String
    let standardErrorPath: String

    enum CodingKeys: String, CodingKey {
      case label = "Label"
      case program = "Program"
      case programArguments = "ProgramArguments"
      case runAtLoad = "RunAtLoad"
      case keepAlive = "KeepAlive"
      case standardOutPath = "StandardOutPath"
      case standardErrorPath = "StandardErrorPath"
    }
  }
}
