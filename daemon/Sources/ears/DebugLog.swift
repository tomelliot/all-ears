import Foundation

/// Stderr debug tracing for `ears` subcommands, gated by ``ClientOptions``'
/// `--verbose`/`-v` — the standing instrumentation for debugging a client↔
/// daemon exchange (which socket was resolved, what was sent, what came back,
/// when the stream closed) without editing code first.
///
/// Deliberately *not* the `docs/logging.md` `LogSink` pipeline: these are
/// interactive one-shot commands whose stdout carries the command's real
/// output (`--json` for scripting), so `--verbose` is a human-facing trace on
/// stderr — off by default, zero-cost when off — complementing, not
/// replacing, the structured JSON Lines sinks the long-running tools use.
struct DebugLog: Sendable {
  var enabled: Bool

  /// Writes one `ears[debug]:`-prefixed line to stderr when enabled. The
  /// message is an autoclosure so disabled runs never pay to format it.
  func log(_ message: @autoclosure () -> String) {
    guard enabled else { return }
    ControlClientRuntime.writeStderr("ears[debug]: \(message())")
  }

  /// `value` rendered as compact, key-sorted JSON for a trace line — the
  /// closest printable stand-in for the wire bytes, since requests, replies,
  /// and subscribe lines are all newline-delimited JSON of these same
  /// `Codable` types.
  func json(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8)
    else {
      return "<unencodable \(type(of: value))>"
    }
    return text
  }
}
