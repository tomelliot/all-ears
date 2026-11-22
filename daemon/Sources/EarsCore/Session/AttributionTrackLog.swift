import Foundation

/// One page-side audio track's history, folded from the session's
/// attribution flight-recorder log (`attribution.jsonl`): whether capture
/// admitted it, under which capture handle, and which platform participant
/// ids the browser linked it to. The track-first view `ears session trace`
/// prints, beside ``AttributionBindingHints``' link-first one.
public struct AttributionTrack: Sendable, Hashable {
  /// The page's `MediaStreamTrack` id.
  public var trackId: String
  /// The provenance verdict at `track-appeared` (`remote` / `local`), when
  /// one existed.
  public var origin: String?
  /// Why admission waited (`deferred`), if it did.
  public var deferredReason: String?
  /// The capture handle (`t1`) the first `admitted` event recorded the track
  /// under — the suffix of its earsd source label. Nil: never admitted.
  public var captureId: String?
  /// Platform participant ids from `identity-link` events, in
  /// first-appearance order, deduplicated.
  public var platformIDs: [String]
  /// Decoded speech onsets (`audio-onset` with `state: start`).
  public var speechOnsets: Int
  /// Why the track was retired as the user's own audio, if it was.
  public var retiredReason: String?

  public init(
    trackId: String, origin: String? = nil, deferredReason: String? = nil,
    captureId: String? = nil, platformIDs: [String] = [], speechOnsets: Int = 0,
    retiredReason: String? = nil
  ) {
    self.trackId = trackId
    self.origin = origin
    self.deferredReason = deferredReason
    self.captureId = captureId
    self.platformIDs = platformIDs
    self.speechOnsets = speechOnsets
    self.retiredReason = retiredReason
  }
}

/// Pure parser from attribution-log JSONL text to per-track
/// ``AttributionTrack``s. Same tolerance contract as
/// ``AttributionBindingHints`` — foreign lines, unknown schemas, malformed
/// JSON, and events without a `trackId` are skipped, never guessed at.
public enum AttributionTrackLog {

  /// Tracks in first-appearance order.
  public static func parse(jsonl: String) -> [AttributionTrack] {
    var order: [String] = []
    var tracks: [String: AttributionTrack] = [:]

    for line in jsonl.split(separator: "\n") {
      guard let object = AttributionBindingHints.decode(line),
        let type = object["type"] as? String,
        let trackId = object["trackId"] as? String
      else { continue }
      if tracks[trackId] == nil {
        order.append(trackId)
        tracks[trackId] = AttributionTrack(trackId: trackId)
      }
      switch type {
      case "track-appeared":
        tracks[trackId]?.origin = object["origin"] as? String
      case "deferred":
        tracks[trackId]?.deferredReason = object["reason"] as? String
      case "admitted":
        // A re-admission (identity-upgrade restart) keeps the first handle.
        if tracks[trackId]?.captureId == nil {
          tracks[trackId]?.captureId = object["participantId"] as? String
        }
      case "identity-link":
        guard let platformID = object["participantId"] as? String,
          tracks[trackId]?.platformIDs.contains(platformID) == false
        else { continue }
        tracks[trackId]?.platformIDs.append(platformID)
      case "audio-onset":
        if object["state"] as? String == "start" { tracks[trackId]?.speechOnsets += 1 }
      case "retired":
        tracks[trackId]?.retiredReason = object["reason"] as? String
      default:
        continue
      }
    }
    return order.compactMap { tracks[$0] }
  }
}
