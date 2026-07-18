import EarsCore

/// Structured JSON Lines log sink plus the `os.Logger` unified-logging mirror,
/// per `docs/logging.md`. The JSON stream is authoritative; the unified-logging
/// mirror is a convenience view for Console.app and Instruments.
public enum EarsLogging {
  /// Version of the `EarsLogging` module.
  public static let version = "0.1.0"
}
