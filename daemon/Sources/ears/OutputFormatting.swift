import EarsCore
import Foundation

/// Renders a `ControlResponse<Payload>` for `ears`'s stdout -- either
/// `--json` (the raw wire JSON, for scripting per `docs/specs/capture-daemon.md`'s
/// "Output is human-readable by default, `--json` for scripting") or a
/// short human-readable summary per payload type.
enum OutputFormatting {
  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  /// Prints `response` and returns the process exit code: `0` for a
  /// successful reply, `1` for a `ControlError` (the message is printed to
  /// stderr either way `json` is set, since a script parsing stdout as JSON
  /// shouldn't have to also parse an error out of it).
  static func emit<Payload: Codable & Sendable & Hashable>(
    _ response: ControlResponse<Payload>, json: Bool, humanSuccess: (Payload) -> String
  ) -> Int32 {
    switch response {
    case .success(let payload):
      if json {
        printJSON(payload)
      } else {
        print(humanSuccess(payload))
      }
      return 0
    case .failure(let error):
      ControlClientRuntime.writeStderr("error: \(error.message)")
      return 1
    }
  }

  private static func printJSON(_ payload: some Encodable) {
    guard let data = try? jsonEncoder.encode(payload),
      let string = String(data: data, encoding: .utf8)
    else {
      print("{}")
      return
    }
    print(string)
  }

  // MARK: - Per-payload human renderers

  static func humanStatus(_ data: StatusData) -> String {
    var lines = ["uptime: \(data.uptimeSeconds)s"]
    lines.append(contentsOf: data.sources.map(humanSourceLine))
    return lines.joined(separator: "\n")
  }

  static func humanSourcesList(_ data: SourcesListData) -> String {
    data.sources.isEmpty
      ? "(no sources)" : data.sources.map(humanSourceLine).joined(separator: "\n")
  }

  private static func humanSourceLine(_ source: SourceStatus) -> String {
    "\(source.id.rawValue)\t\(source.state.rawValue)\t\(source.codec)\tbytes_used=\(source.bytesUsed)"
  }

  static func humanSessionOpen(_ data: SessionOpenData) -> String {
    data.id
  }

  static func humanSessionList(_ data: SessionListData) -> String {
    data.sessions.isEmpty
      ? "(no sessions)"
      : data.sessions.map {
        "\($0.id)\t\($0.state.rawValue)\tsources=\($0.sources.map(\.rawValue).joined(separator: ","))"
      }
      .joined(separator: "\n")
  }

  static func humanEmpty(_: EmptyData) -> String {
    "ok"
  }

  static func humanEvent(_ event: EarsEvent) -> String {
    switch event {
    case .vad(let source, let state, let t):
      return "[\(t)] vad \(source.rawValue) \(state.rawValue)"
    case .session(let id, let state):
      return "[session] \(id) \(state.rawValue)"
    case .segment(let session, let speaker, let start, let end, let text):
      return "[\(session)] \(speaker) (\(start)-\(end)): \(text)"
    }
  }
}
