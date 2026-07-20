import EarsCore
import Foundation

/// Renders v2 results for `ears`'s stdout -- either `--json` (the raw result
/// payload, for scripting) or a short human-readable summary per payload
/// type. Wire errors are handled by ``ControlClientRuntime/send``'s caller
/// (they arrive as thrown `WireError`s).
enum OutputFormatting {
  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  /// Prints a successful result and returns exit code 0.
  static func emit<Payload: Codable & Sendable & Hashable>(
    _ payload: Payload, json: Bool, humanSuccess: (Payload) -> String
  ) -> Int32 {
    if json {
      printJSON(payload)
    } else {
      print(humanSuccess(payload))
    }
    return 0
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
    if !data.meetings.isEmpty {
      lines.append(contentsOf: data.meetings.map(humanMeetingLine))
    }
    if !data.sessions.isEmpty {
      lines.append(
        contentsOf: data.sessions.map {
          "session \($0.id)\t\($0.state.rawValue)"
        })
    }
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

  static func humanMeeting(_ meeting: Meeting) -> String {
    humanMeetingLine(meeting)
  }

  static func humanMeetingList(_ data: MeetingListData) -> String {
    humanMeetings(data.meetings)
  }

  static func humanMeetings(_ meetings: [Meeting]) -> String {
    meetings.isEmpty
      ? "(no meetings)" : meetings.map(humanMeetingLine).joined(separator: "\n")
  }

  static func humanMeetingLine(_ meeting: Meeting) -> String {
    var parts = [
      meeting.id,
      meeting.state.rawValue,
      "\"\(meeting.title)\"",
    ]
    if let identity = meeting.identity {
      parts.append("\(identity.platform):\(identity.externalID)")
    }
    parts.append("intervals=\(meeting.intervals.count)")
    if !meeting.attendees.isEmpty {
      parts.append("attendees=\(meeting.attendees.count)")
    }
    return parts.joined(separator: "\t")
  }

  static func humanEvent(_ frame: EventFrame) -> String {
    let revSuffix = frame.rev.map { " rev=\($0)" } ?? ""
    switch frame.event {
    case .vad(let source, let state, let t):
      return "[\(t)] vad \(source.rawValue) \(state.rawValue)"
    case .session(let summary):
      return "[session] \(summary.id) \(summary.state.rawValue)\(revSuffix)"
    case .segment(let segment):
      return
        "[\(segment.session)] \(segment.speaker) (\(segment.start)-\(segment.end)): \(segment.text)"
    case .meeting(let meeting):
      return "[meeting] \(humanMeetingLine(meeting))\(revSuffix)"
    case .source(let id, let state):
      return "[source] \(id.rawValue) \(state.rawValue)\(revSuffix)"
    case .job(let job):
      let target = job.meeting.map { " meeting=\($0)" } ?? job.session.map { " session=\($0)" } ?? ""
      return "[job] \(job.job) \(job.kind)\(target) \(job.state.rawValue)"
    }
  }
}
