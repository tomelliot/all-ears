import Foundation

/// One identity binding the browser's capture layer forwarded during a call,
/// recovered from the session's attribution flight-recorder log
/// (`attribution.jsonl` — see `docs/data-formats.md`).
///
/// Since R3 a browser source id is an opaque per-track handle
/// (`browser:<platform>:<slug>`), so the roster's single `source` link per
/// attendee can under-report: one participant may own several sources across
/// a call (a rejoin, a seam swap), and an identity may confirm after its
/// track — or the whole session — is gone. The flight recorder's
/// `identity-link` events carry *every* link the browser forwarded, each
/// joined (by track id) to the `provisional-binding` decision that caused it,
/// and ``RosterReconciler`` consumes them as additional claims beside the
/// roster's own.
public struct AttributionBindingHint: Sendable, Hashable {
  /// The capture handle the audio is recorded under (`t3`) — the suffix of
  /// the earsd source label this hint names.
  public var captureId: String
  /// The platform participant id the browser linked the source to — an
  /// attendee row's `id`.
  public var attendeeID: String
  /// The page-side track id, joining the link to its binding decision.
  public var trackId: String
  /// Epoch ms when the link was forwarded.
  public var t: Double
  /// The correlator whose confirmed match caused the link (`collections`,
  /// `unmute`, `dom`), or nil for an admission-time identify (Zoom MSID, a
  /// Meet tile hit), which needs no correlation.
  public var correlator: String?
  /// Confirming turns the correlator counted, when one caused the link.
  public var confirmations: Int?

  public init(
    captureId: String, attendeeID: String, trackId: String, t: Double,
    correlator: String? = nil, confirmations: Int? = nil
  ) {
    self.captureId = captureId
    self.attendeeID = attendeeID
    self.trackId = trackId
    self.t = t
    self.correlator = correlator
    self.confirmations = confirmations
  }
}

/// What the flight recorder *heard* during a call — the evidence that
/// separates "this track / this person was silent" from "we lost their
/// audio". Consumed by ``RosterReconciler`` to keep silence unremarkable:
/// a captured-but-silent track deserves no warning and no speaker row, while
/// a person the platform showed speaking whose audio matched nothing is a
/// loss worth recording (journal #181).
public struct AttributionSpeechEvidence: Sendable, Equatable {
  /// Capture handles (`t1`) whose track produced at least one decoded speech
  /// onset (`audio-onset` events). A browser source whose handle is absent
  /// was captured but never carried speech.
  public var speechCaptures: Set<String>
  /// `dom-burst` counts per platform device id — the platform's own speaking
  /// indicator, independent of whether capture decoded anything.
  public var burstCounts: [String: Int]

  public init(speechCaptures: Set<String> = [], burstCounts: [String: Int] = [:]) {
    self.speechCaptures = speechCaptures
    self.burstCounts = burstCounts
  }
}

/// Pure parser from attribution-log JSONL text to ``AttributionBindingHint``s.
/// The browser owns the event vocabulary (`browser/lib/attribution-log.ts`,
/// per-line `schema`); this reads exactly the two event types the binding
/// question needs and skips everything else — foreign lines, unknown schemas,
/// and malformed JSON are ignored, never guessed at.
public enum AttributionBindingHints {

  /// Parses `jsonl` (one JSON object per line). Hints are returned in
  /// first-appearance order; a repeated (captureId, attendeeID) link — the
  /// browser re-forwards on service-worker respawn — collapses to its first
  /// occurrence.
  public static func parse(jsonl: String) -> [AttributionBindingHint] {
    // outcome `bound` / `bound-late-rename` decisions by trackId+deviceId,
    // first occurrence kept: the decision that actually caused the link.
    var causes: [String: (correlator: String, confirmations: Int)] = [:]
    var hints: [AttributionBindingHint] = []
    var seen: Set<String> = []

    for line in jsonl.split(separator: "\n") {
      guard let object = decode(line) else { continue }
      guard let type = object["type"] as? String else { continue }
      switch type {
      case "provisional-binding":
        guard let trackId = object["trackId"] as? String,
          let deviceId = object["deviceId"] as? String,
          let outcome = object["outcome"] as? String,
          outcome == "bound" || outcome == "bound-late-rename",
          let correlator = object["correlator"] as? String,
          let confirmations = object["confirmations"] as? Int
        else { continue }
        let key = "\(trackId)\u{0}\(deviceId)"
        if causes[key] == nil { causes[key] = (correlator, confirmations) }
      case "identity-link":
        guard let trackId = object["trackId"] as? String,
          let captureId = object["captureId"] as? String,
          let attendeeID = object["participantId"] as? String,
          let t = numeric(object["t"])
        else { continue }
        let dedupeKey = "\(captureId)\u{0}\(attendeeID)"
        guard seen.insert(dedupeKey).inserted else { continue }
        let cause = causes["\(trackId)\u{0}\(attendeeID)"]
        hints.append(
          AttributionBindingHint(
            captureId: captureId, attendeeID: attendeeID, trackId: trackId, t: t,
            correlator: cause?.correlator, confirmations: cause?.confirmations))
      default:
        continue
      }
    }
    return hints
  }

  /// Parses `jsonl` for the speech evidence: which captures produced decoded
  /// audio onsets, and how often each device's DOM speaking ring fired. Same
  /// tolerance contract as ``parse(jsonl:)`` — foreign lines, unknown
  /// schemas, and malformed JSON are skipped, never guessed at.
  public static func speechEvidence(jsonl: String) -> AttributionSpeechEvidence {
    var evidence = AttributionSpeechEvidence()
    for line in jsonl.split(separator: "\n") {
      guard let object = decode(line) else { continue }
      switch object["type"] as? String {
      case "audio-onset":
        guard let captureId = object["participantId"] as? String else { continue }
        evidence.speechCaptures.insert(captureId)
      case "dom-burst":
        guard let deviceId = object["deviceId"] as? String else { continue }
        evidence.burstCounts[deviceId, default: 0] += 1
      default:
        continue
      }
    }
    return evidence
  }

  static func decode(_ line: Substring) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard
      let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
      let object = parsed as? [String: Any],
      object["schema"] as? Int == 1
    else { return nil }
    return object
  }

  private static func numeric(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    return nil
  }
}
