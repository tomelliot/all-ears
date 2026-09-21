import EarsCore
import Foundation

/// Maps the ``Session`` entity to and from the `ConfigValue` tree that
/// mirrors `session.toml` **schema 3**
/// (`<data-root>/sessions/<uuid>/session.toml`) — the daemon-owned lifecycle
/// record of `docs/specs/control-protocol.md`. Schema 1 (the dead v1
/// identity-only `session.toml`) and schema 2 (the pre-rename
/// `meetings/<uuid>/meeting.toml`) are dead formats: they are ignored, never
/// read. `TOMLBridge` does the actual TOML text, this file only knows the
/// fields.
///
/// Optional scalars use the suite's "empty string ⇒ absent" sentinel
/// convention; `interval` and `attendee` are arrays of tables. `rev` is
/// deliberately **not** persisted — revisions are scoped to a daemon boot
/// (`hello`'s `boot_id`), so a persisted one would be a lie after restart.
public enum SessionDescriptorTOML {
  /// The `session.toml` schema version this build reads and writes.
  /// Bumped to 3 on the meeting→session rename so any stale schema-1 or
  /// schema-2 file on disk is unambiguously a dead format.
  public static let schemaVersion = 3

  /// Encodes a ``Session`` into the `ConfigValue` table `session.toml`
  /// serializes to.
  public static func encode(_ session: Session) -> ConfigValue {
    .table([
      "schema": .int(schemaVersion),
      "id": .string(session.id),
      "platform": .string(session.identity?.platform ?? ""),
      "external_id": .string(session.identity?.externalID ?? ""),
      "title": .string(session.title),
      "state": .string(session.state.rawValue),
      "started": .string(formatInstant(session.started)),
      "ended": .string(session.ended.map(formatInstant) ?? ""),
      "transcript_completed": .string(session.transcriptCompleted.map(formatInstant) ?? ""),
      "trigger": .string(session.trigger.rawValue),
      "sources": .array(session.sources.map { .string($0.rawValue) }),
      "interval": .array(
        session.intervals.map { interval in
          .table([
            "start": .string(formatInstant(interval.start)),
            "end": .string(interval.end.map(formatInstant) ?? ""),
          ])
        }),
      "warnings": .array(session.warnings.map { .string($0) }),
      "pipeline_issue": .array(
        session.pipelineIssues.map { issue in
          .table([
            "stage": .string(issue.stage),
            "kind": .string(issue.kind.rawValue),
            "message": .string(issue.message),
            "exit_class": .string(issue.exitClass ?? ""),
          ])
        }),
      "published_notes": .array(session.publishedNotes.map { .string($0) }),
      "attendee": .array(
        session.attendees.map { attendee in
          .table([
            "id": .string(attendee.id),
            "display_name": .string(attendee.displayName ?? ""),
            "joined": .string(attendee.joined.map(formatInstant) ?? ""),
            "left": .string(attendee.left.map(formatInstant) ?? ""),
            "source": .string(attendee.source?.rawValue ?? ""),
            // "" = unknown (the suite's absent sentinel): a roster row
            // recorded before provenance existed, or an id whose join the
            // client never saw. Readers treat unknown exactly as pre-origin
            // rows — see `RosterReconciler.namedRemoteAttendees`.
            "origin": .string(attendee.origin?.rawValue ?? ""),
            "self": .bool(attendee.isLocal),
          ])
        }),
      // Which reconciler derived the `speaker` map below — 0 for a session
      // never reconciled. `transcribe` re-derives a map older than the
      // current `RosterReconciler.version`, so a reconciler fix repairs past
      // sessions instead of only future ones.
      "reconciler_version": .int(session.reconcilerVersion),
      // The reconciled derivation, kept beside the roster it came from rather
      // than replacing it: `attendee` stays the observed record, `speaker` is
      // what `RosterReconciler` concluded, and having both on disk is what
      // makes a wrong conclusion diagnosable after the fact.
      "speaker": .array(
        session.speakers.map { speaker in
          .table([
            "source": .string(speaker.source.rawValue),
            "name": .string(speaker.name),
            "confidence": .string(speaker.confidence.rawValue),
          ])
        }),
    ])
  }

  /// Decodes a ``Session`` from a `ConfigValue` table parsed from
  /// `session.toml`. Rejects any schema other than ``schemaVersion`` —
  /// tools reject a schema they don't understand rather than guessing
  /// (`docs/data-formats.md`).
  public static func decode(_ value: ConfigValue) throws(DescriptorTOMLError) -> Session {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    guard try fields.int("schema") == schemaVersion else {
      throw .invalidField("schema")
    }
    guard let state = SessionState(rawValue: try fields.string("state")) else {
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

    let transcriptCompleted: Instant?
    if let raw = fields.optionalString("transcript_completed") {
      guard let parsed = parseInstant(raw) else { throw .invalidField("transcript_completed") }
      transcriptCompleted = parsed
    } else {
      transcriptCompleted = nil
    }

    // An identity is both halves or neither. Half an identity is a corrupt
    // file, not a manual session — decoding it to nil would silently break
    // `session.start` idempotency for the reloaded record, so it is rejected
    // like any other invalid field, naming the half that is missing.
    let identity: SessionIdentity?
    switch (fields.optionalString("platform"), fields.optionalString("external_id")) {
    case (let platform?, let externalID?):
      identity = SessionIdentity(platform: platform, externalID: externalID)
    case (nil, nil):
      identity = nil
    case (.some, nil):
      throw .invalidField("external_id")
    case (nil, .some):
      throw .invalidField("platform")
    }

    var sources: [SourceID] = []
    for element in try fields.array("sources") {
      guard case .string(let raw) = element else { throw .invalidField("sources") }
      sources.append(SourceID(raw))
    }

    var intervals: [SessionInterval] = []
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
      intervals.append(SessionInterval(start: start, end: end))
    }

    var attendees: [SessionAttendee] = []
    for element in try fields.array("attendee") {
      guard case .table(let attendeeTable) = element else { throw .invalidField("attendee") }
      let attendeeFields = TOMLFieldReader(table: attendeeTable)
      // Absent (or "") = unknown, for every file written before the field
      // existed; a present-but-unrecognised value is rejected like any other
      // enum field rather than being quietly read as unknown.
      let origin: AttendeeOrigin?
      if let originRaw = attendeeFields.optionalString("origin") {
        guard let parsed = AttendeeOrigin(rawValue: originRaw) else {
          throw .invalidField("attendee.origin")
        }
        origin = parsed
      } else {
        origin = nil
      }
      attendees.append(
        SessionAttendee(
          id: try attendeeFields.string("id"),
          displayName: attendeeFields.optionalString("display_name"),
          joined: attendeeFields.optionalString("joined").flatMap(parseInstant),
          left: attendeeFields.optionalString("left").flatMap(parseInstant),
          source: attendeeFields.optionalString("source").map { SourceID($0) },
          origin: origin,
          isLocal: attendeeFields.optionalBool("self")))
    }

    // `speaker`/`warnings` post-date schema 3's first files, so both read
    // tolerantly: a session captured before reconciliation existed simply has
    // an empty speaker map, which is exactly what it knew.
    var speakers: [SessionSpeaker] = []
    for element in fields.optionalArray("speaker") {
      guard case .table(let speakerTable) = element else { throw .invalidField("speaker") }
      let speakerFields = TOMLFieldReader(table: speakerTable)
      guard
        let confidence = SpeakerConfidence(rawValue: try speakerFields.string("confidence"))
      else { throw .invalidField("speaker.confidence") }
      speakers.append(
        SessionSpeaker(
          source: SourceID(try speakerFields.string("source")),
          name: try speakerFields.string("name"),
          confidence: confidence))
    }

    var warnings: [String] = []
    for element in fields.optionalArray("warnings") {
      guard case .string(let warning) = element else { throw .invalidField("warnings") }
      warnings.append(warning)
    }

    // Post-dates schema 3's first files too: absent reads as no issues.
    var pipelineIssues: [PipelineIssue] = []
    for element in fields.optionalArray("pipeline_issue") {
      guard case .table(let issueTable) = element else { throw .invalidField("pipeline_issue") }
      let issueFields = TOMLFieldReader(table: issueTable)
      guard let kind = PipelineIssue.Kind(rawValue: try issueFields.string("kind")) else {
        throw .invalidField("pipeline_issue.kind")
      }
      pipelineIssues.append(
        PipelineIssue(
          stage: try issueFields.string("stage"),
          kind: kind,
          message: try issueFields.string("message"),
          exitClass: issueFields.optionalString("exit_class")))
    }

    // Post-dates schema 3's first files too: absent reads as none.
    var publishedNotes: [String] = []
    for element in fields.optionalArray("published_notes") {
      guard case .string(let path) = element else { throw .invalidField("published_notes") }
      publishedNotes.append(path)
    }

    return Session(
      id: try fields.string("id"),
      identity: identity,
      title: try fields.string("title"),
      state: state,
      started: started,
      ended: ended,
      intervals: intervals,
      attendees: attendees,
      speakers: speakers,
      warnings: warnings,
      sources: sources,
      trigger: trigger,
      transcriptCompleted: transcriptCompleted,
      pipelineIssues: pipelineIssues,
      publishedNotes: publishedNotes,
      // Absent = 0: a file from before reconciliation was versioned, which
      // every consumer treats as "older than any current reconciler".
      reconcilerVersion: fields.optionalInt("reconciler_version"))
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
