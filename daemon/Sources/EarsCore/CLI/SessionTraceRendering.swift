import Foundation

/// Renders `ears session trace`: for one session, the chain that names each
/// speaker — browser track → capture handle → platform participant id →
/// roster display name → speaker label — built only from meeting data (the
/// roster, the speaker map, the attribution log), never from transcript
/// text. Words per source/label from the transcript follow as a check, and a
/// closing `problems` section flags each broken link.
public enum SessionTraceRendering {
  /// A UUID track id shortened to its first block; any other id in full.
  /// Jitsi's SSRC-rewriting slots (`remote-audio-1`, `remote-audio-2`, …)
  /// share their first eight characters, so a blind prefix merges them.
  static func shortTrackID(_ id: String) -> String {
    UUID(uuidString: id) != nil ? String(id.prefix(8)) : id
  }

  /// - Parameters:
  ///   - tracks: ``AttributionTrackLog/parse(jsonl:)`` of `attribution.jsonl`,
  ///     or nil when the session has no attribution log.
  ///   - segments: the `transcript.json` segments, or nil when there is none.
  public static func render(
    session: Session, tracks: [AttributionTrack]?, segments: [TranscriptSegment]?
  ) -> String {
    var lines: [String] = []
    let platform = session.identity?.platform ?? "-"
    lines.append("\(session.title) — \(session.id.prefix(8))  platform=\(platform)")
    lines.append("  sources  \(session.sources.map(\.rawValue).joined(separator: ", "))")
    lines.append(contentsOf: session.warnings.map { "  ⚠ \($0)" })

    lines.append("")
    lines.append("attendees (daemon roster)")
    if session.attendees.isEmpty { lines.append("  none") }
    lines.append(
      contentsOf: table(
        session.attendees.map {
          [
            $0.id, "origin=\($0.origin?.rawValue ?? "-")", "self=\($0.isLocal)",
            "name=\(quoted($0.displayName))", "source=\($0.source?.rawValue ?? "-")",
          ]
        }))

    lines.append("")
    lines.append("speakers (transcript labels)")
    if session.speakers.isEmpty { lines.append("  none") }
    lines.append(
      contentsOf: table(
        session.speakers.map {
          [$0.source.rawValue, "-> \(quoted($0.name))", "(\($0.confidence.rawValue))"]
        }))

    lines.append("")
    lines.append("tracks (browser attribution log)")
    if let tracks {
      if tracks.isEmpty { lines.append("  none") }
      lines.append(contentsOf: table(tracks.map(trackRow)))
    } else {
      lines.append("  no attribution.jsonl")
    }

    let chain = chainLinks(session: session, tracks: tracks ?? [])
    lines.append("")
    lines.append("chain (track -> capture -> platform id -> name -> label)")
    if chain.isEmpty { lines.append("  none") }
    lines.append(
      contentsOf: table(
        chain.map { link in
          [
            shortTrackID(link.trackId), "-> \(link.captureId)",
            "-> \(link.platformID ?? "?")",
            "-> \(link.platformID == nil ? "?" : quoted(link.name))",
            "-> \(link.label.map(quoted) ?? "?")  (\(link.source.rawValue))",
          ]
        }))

    let words = segments.map(wordCounts)
    lines.append("")
    lines.append("words per source / label (transcript.json)")
    if let words {
      if words.isEmpty { lines.append("  none") }
      lines.append(
        contentsOf: table(words.map { [$0.source.rawValue, $0.label, String($0.words)] }))
    } else {
      lines.append("  no transcript.json")
    }

    let found = problems(session: session, tracks: tracks ?? [], chain: chain, words: words ?? [])
    lines.append("")
    lines.append("problems")
    lines.append(contentsOf: found.isEmpty ? ["  none"] : found.map { "  ⚠ \($0)" })
    return lines.joined(separator: "\n")
  }

  // MARK: - Derivation

  /// One admitted track's walk from capture handle to label; one row per
  /// platform id the track was linked to, or one with `platformID: nil`.
  struct ChainLink: Equatable {
    var trackId: String
    var captureId: String
    var source: SourceID
    var platformID: String?
    /// The roster display name for `platformID`; nil when no row has it.
    var name: String?
    /// The speaker-map name for `source`; nil when the map has no entry.
    var label: String?
  }

  static func chainLinks(session: Session, tracks: [AttributionTrack]) -> [ChainLink] {
    var links: [ChainLink] = []
    for track in tracks {
      guard let captureId = track.captureId else { continue }
      let source = sourceID(forCapture: captureId, in: session)
      let label = session.speakers.first { $0.source == source }?.name
      let platformIDs: [String?] = track.platformIDs.isEmpty ? [nil] : track.platformIDs
      for platformID in platformIDs {
        let name = platformID.flatMap { id in
          session.attendees.first { $0.id == id }.map { $0.displayName ?? "" }
        }
        links.append(
          ChainLink(
            trackId: track.trackId, captureId: captureId, source: source,
            platformID: platformID, name: name, label: label))
      }
    }
    return links
  }

  /// The earsd source a capture handle records under: the session's browser
  /// source whose last `:` component is the handle (`browser:meet:t2` → `t2`).
  static func sourceID(forCapture captureId: String, in session: Session) -> SourceID {
    let candidates = session.sources + session.attendees.compactMap(\.source)
    if let match = candidates.first(where: {
      $0.sourceClass == .browser
        && $0.rawValue.split(separator: ":").last.map(String.init) == captureId
    }) {
      return match
    }
    return SourceID("browser:\(session.identity?.platform ?? "?"):\(captureId)")
  }

  struct WordCount: Equatable {
    var source: SourceID
    var label: String
    var words: Int
  }

  /// Words per (source, label), most first; ties in first-appearance order.
  static func wordCounts(_ segments: [TranscriptSegment]) -> [WordCount] {
    var counts: [WordCount] = []
    for segment in segments {
      let words = segment.segment.text.split(whereSeparator: \.isWhitespace).count
      if let index = counts.firstIndex(where: {
        $0.source == segment.source && $0.label == segment.speaker
      }) {
        counts[index].words += words
      } else {
        counts.append(WordCount(source: segment.source, label: segment.speaker, words: words))
      }
    }
    return counts.enumerated()
      .sorted { ($0.element.words, -$0.offset) > ($1.element.words, -$1.offset) }
      .map(\.element)
  }

  static func problems(
    session: Session, tracks: [AttributionTrack], chain: [ChainLink], words: [WordCount]
  ) -> [String] {
    var found: [String] = []

    for track in tracks where track.speechOnsets > 0 && track.platformIDs.isEmpty {
      found.append(
        "track \(shortTrackID(track.trackId)) (capture \(track.captureId ?? "-")) carried "
          + "\(track.speechOnsets) speech onset\(track.speechOnsets == 1 ? "" : "s") but was never "
          + "linked to a platform id")
    }

    var reported: Set<String> = []
    for link in chain {
      guard let platformID = link.platformID, reported.insert(platformID).inserted else {
        continue
      }
      switch link.name {
      case nil:
        found.append(
          "platform id \(platformID) (track \(shortTrackID(link.trackId))) has no roster row")
      case let name? where name.isEmpty:
        found.append("platform id \(platformID) has no display name in the roster")
      default:
        break
      }
    }

    // Every name meeting data attaches to a source: roster rows, the speaker
    // map, and names reached through identity links.
    var namesBySource: [SourceID: [String]] = [:]
    func claim(_ source: SourceID, _ name: String?) {
      guard let name, !name.isEmpty, namesBySource[source]?.contains(name) != true else { return }
      namesBySource[source, default: []].append(name)
    }
    for attendee in session.attendees {
      if let source = attendee.source { claim(source, attendee.displayName) }
    }
    for link in chain { claim(link.source, link.name) }
    for speaker in session.speakers { claim(speaker.source, speaker.name) }
    for source in namesBySource.keys.sorted() where namesBySource[source]!.count > 1 {
      let names = namesBySource[source]!.map(quoted).joined(separator: " and ")
      found.append("\(source.rawValue) is claimed by \(names)")
    }

    if !session.attendees.isEmpty && !session.attendees.contains(where: \.isLocal) {
      found.append("no attendee has self=true — the local participant is unknown")
    }

    for speaker in session.speakers
    where !chain.contains(where: { $0.source == speaker.source && $0.name == speaker.name }) {
      found.append(
        "\(speaker.source.rawValue) is labelled \(quoted(speaker.name)) "
          + "(\(speaker.confidence.rawValue)) but no identity link names it")
    }

    for count in words {
      if let speaker = session.speakers.first(where: { $0.source == count.source }) {
        if speaker.name != count.label {
          found.append(
            "\(count.words) words on \(count.source.rawValue) are labelled "
              + "\(quoted(count.label)), but the speaker map says \(quoted(speaker.name))")
        }
      } else if count.source.sourceClass == .browser {
        found.append(
          "\(count.words) words on \(count.source.rawValue) have no speaker map entry")
      }
    }
    return found
  }

  // MARK: - Formatting

  private static func trackRow(_ track: AttributionTrack) -> [String] {
    var note = ""
    if let reason = track.retiredReason {
      note = "(retired: \(reason))"
    } else if track.captureId == nil && track.origin == nil {
      // Only later events (speech onsets) reached the log: the track's
      // appearance and admission were recorded before the session existed.
      note = "(admission not in the log)"
    } else if track.captureId == nil {
      note = "(never admitted" + (track.deferredReason.map { ": deferred, \($0)" } ?? "") + ")"
    }
    return [
      shortTrackID(track.trackId), "origin=\(track.origin ?? "-")",
      "capture=\(track.captureId ?? "-")",
      "platform_id=\(track.platformIDs.isEmpty ? "-" : track.platformIDs.joined(separator: ","))",
      "speech_onsets=\(track.speechOnsets)", note,
    ]
  }

  private static func quoted(_ name: String?) -> String { "'\(name ?? "")'" }

  /// Two-space-indented rows with every column but the last padded to its
  /// widest cell; trailing blanks trimmed.
  private static func table(_ rows: [[String]]) -> [String] {
    let columns = rows.map(\.count).max() ?? 0
    let widths = (0..<columns).map { column in
      rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
    }
    return rows.map { row in
      let cells = row.enumerated().map { index, cell in
        index == row.count - 1
          ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
      }
      let line = "  " + cells.joined(separator: "  ")
      return String(line.reversed().drop(while: { $0 == " " }).reversed())
    }
  }
}
