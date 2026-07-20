import EarsCore
import Foundation

/// Maps the v2 ``Meeting`` entity to and from the `ConfigValue` tree that
/// mirrors `meeting.toml` **schema 2**
/// (`<data-root>/meetings/<uuid>/meeting.toml`) — the daemon-owned lifecycle
/// record of `docs/specs/control-protocol.md`, superseding schema 1's
/// identity-only shape. Mirrors ``SessionDescriptorTOML``: `TOMLBridge` does
/// the actual TOML text, this file only knows the fields.
///
/// Optional scalars use the suite's "empty string ⇒ absent" sentinel
/// convention; `interval` and `attendee` are arrays of tables. `rev` is
/// deliberately **not** persisted — revisions are scoped to a daemon boot
/// (`hello`'s `boot_id`), so a persisted one would be a lie after restart.
public enum MeetingDescriptorTOML {
  /// The `meeting.toml` schema version this build reads and writes.
  public static let schemaVersion = 2

  /// Encodes a ``Meeting`` into the `ConfigValue` table `meeting.toml`
  /// serializes to.
  public static func encode(_ meeting: Meeting) -> ConfigValue {
    .table([
      "schema": .int(schemaVersion),
      "id": .string(meeting.id),
      "platform": .string(meeting.identity?.platform ?? ""),
      "external_id": .string(meeting.identity?.externalID ?? ""),
      "title": .string(meeting.title),
      "state": .string(meeting.state.rawValue),
      "started": .string(formatInstant(meeting.started)),
      "ended": .string(meeting.ended.map(formatInstant) ?? ""),
      "trigger": .string(meeting.trigger.rawValue),
      "sources": .array(meeting.sources.map { .string($0.rawValue) }),
      "interval": .array(
        meeting.intervals.map { interval in
          .table([
            "start": .string(formatInstant(interval.start)),
            "end": .string(interval.end.map(formatInstant) ?? ""),
          ])
        }),
      "attendee": .array(
        meeting.attendees.map { attendee in
          .table([
            "id": .string(attendee.id),
            "display_name": .string(attendee.displayName ?? ""),
            "joined": .string(attendee.joined.map(formatInstant) ?? ""),
            "left": .string(attendee.left.map(formatInstant) ?? ""),
            "source": .string(attendee.source?.rawValue ?? ""),
          ])
        }),
    ])
  }

  /// Decodes a ``Meeting`` from a `ConfigValue` table parsed from
  /// `meeting.toml`. Rejects any schema other than ``schemaVersion`` —
  /// tools reject a schema they don't understand rather than guessing
  /// (`docs/data-formats.md`).
  public static func decode(_ value: ConfigValue) throws(DescriptorTOMLError) -> Meeting {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    guard try fields.int("schema") == schemaVersion else {
      throw .invalidField("schema")
    }
    guard let state = MeetingState(rawValue: try fields.string("state")) else {
      throw .invalidField("state")
    }
    guard let trigger = TriggerKind(rawValue: try fields.string("trigger")) else {
      throw .invalidField("trigger")
    }
    guard let started = parseInstant(try fields.string("started")) else {
      throw .invalidField("started")
    }
    let ended: Instant?
    if let endedRaw = fields.optionalString("ended") {
      guard let parsed = parseInstant(endedRaw) else { throw .invalidField("ended") }
      ended = parsed
    } else {
      ended = nil
    }

    let identity: MeetingIdentity?
    if let platform = fields.optionalString("platform"),
      let externalID = fields.optionalString("external_id")
    {
      identity = MeetingIdentity(platform: platform, externalID: externalID)
    } else {
      identity = nil
    }

    var sources: [SourceID] = []
    for element in try fields.array("sources") {
      guard case .string(let raw) = element else { throw .invalidField("sources") }
      sources.append(SourceID(raw))
    }

    var intervals: [MeetingInterval] = []
    for element in try fields.array("interval") {
      guard case .table(let intervalTable) = element else { throw .invalidField("interval") }
      let intervalFields = TOMLFieldReader(table: intervalTable)
      guard let start = parseInstant(try intervalFields.string("start")) else {
        throw .invalidField("interval.start")
      }
      let end: Instant?
      if let endRaw = intervalFields.optionalString("end") {
        guard let parsed = parseInstant(endRaw) else { throw .invalidField("interval.end") }
        end = parsed
      } else {
        end = nil
      }
      intervals.append(MeetingInterval(start: start, end: end))
    }

    var attendees: [MeetingAttendee] = []
    for element in try fields.array("attendee") {
      guard case .table(let attendeeTable) = element else { throw .invalidField("attendee") }
      let attendeeFields = TOMLFieldReader(table: attendeeTable)
      attendees.append(
        MeetingAttendee(
          id: try attendeeFields.string("id"),
          displayName: attendeeFields.optionalString("display_name"),
          joined: attendeeFields.optionalString("joined").flatMap(parseInstant),
          left: attendeeFields.optionalString("left").flatMap(parseInstant),
          source: attendeeFields.optionalString("source").map { SourceID($0) }))
    }

    return Meeting(
      id: try fields.string("id"),
      identity: identity,
      title: try fields.string("title"),
      state: state,
      started: started,
      ended: ended,
      intervals: intervals,
      attendees: attendees,
      sources: sources,
      trigger: trigger)
  }

  /// Standard colon-separated ISO-8601 UTC, whole seconds.
  private static func formatInstant(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
  }

  private static func parseInstant(_ string: String) -> Instant? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else { return nil }
    return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
  }
}
