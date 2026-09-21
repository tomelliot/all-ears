import Foundation
import Testing

@testable import EarsConfig
@testable import EarsCore

/// Round-trips `Session` through the `session.toml` (schema 3) mapping,
/// focused on the fields whose compatibility rules live in the TOML layer
/// rather than in the entity — above all `reconciler_version`, whose
/// absent-means-0 tolerance is what keeps every pre-versioning session file
/// readable (`docs/data-formats.md`, "Roster and speaker map").
@Suite("SessionDescriptorTOML")
struct SessionDescriptorTOMLTests {
  private static let started = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private static func referenceSession(reconcilerVersion: Int = 0) -> Session {
    Session(
      id: "0d5e7f6a-fixture",
      identity: SessionIdentity(platform: "meet", externalID: "abc-defg-hij"),
      title: "Weekly sync",
      state: .ended,
      started: started,
      ended: started.advanced(by: 1860),
      intervals: [SessionInterval(start: started, end: started.advanced(by: 1860))],
      attendees: [
        SessionAttendee(
          id: "spaces/x/devices/y", displayName: "Jane Doe", joined: started.advanced(by: 12),
          source: SourceID("browser:meet:jane-a1b2"), origin: .platform),
        SessionAttendee(
          id: "speaker-1", joined: started.advanced(by: 40),
          source: SourceID("browser:meet:speaker-1"), origin: .synthetic),
        SessionAttendee(
          id: "speaker-2", joined: started.advanced(by: 90),
          source: SourceID("browser:meet:speaker-2")),
      ],
      speakers: [
        SessionSpeaker(
          source: SourceID("browser:meet:jane-a1b2"), name: "Jane Doe", confidence: .correlated)
      ],
      sources: ["mic", "browser:meet:jane-a1b2"],
      trigger: .browserExtension,
      reconcilerVersion: reconcilerVersion)
  }

  @Test("reconciler_version round-trips beside the speaker map")
  func reconcilerVersionRoundTrips() throws {
    let encoded = SessionDescriptorTOML.encode(
      Self.referenceSession(reconcilerVersion: RosterReconciler.version))
    let decoded = try SessionDescriptorTOML.decode(encoded)

    #expect(decoded.reconcilerVersion == RosterReconciler.version)
    #expect(decoded == Self.referenceSession(reconcilerVersion: RosterReconciler.version))
  }

  @Test("pipeline issues round-trip, and a file without them decodes to none")
  func pipelineIssuesRoundTrip() throws {
    var session = Self.referenceSession()
    session.pipelineIssues = [
      PipelineIssue(
        stage: "summarize", kind: .failed, message: "LLM backend call timed out",
        exitClass: "retryable-upstream"),
      PipelineIssue(stage: "cleanup", kind: .warning, message: "chunk fell back"),
    ]
    #expect(try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(session)) == session)

    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()) else {
      Issue.record("session.toml did not encode to a table")
      return
    }
    table["pipeline_issue"] = nil
    #expect(try SessionDescriptorTOML.decode(.table(table)).pipelineIssues.isEmpty)
  }

  @Test("published notes round-trip, and a file without them decodes to none")
  func publishedNotesRoundTrip() throws {
    var session = Self.referenceSession()
    session.publishedNotes = ["/vault/daily-notes/2026-09-21 - Augustin Applegate.md"]
    #expect(try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(session)) == session)

    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()) else {
      Issue.record("session.toml did not encode to a table")
      return
    }
    table["published_notes"] = nil
    #expect(try SessionDescriptorTOML.decode(.table(table)).publishedNotes.isEmpty)
  }

  @Test("attendee origin round-trips: platform, synthetic, and unknown-as-absent")
  func attendeeOriginRoundTrips() throws {
    let encoded = SessionDescriptorTOML.encode(Self.referenceSession())
    let decoded = try SessionDescriptorTOML.decode(encoded)

    #expect(decoded.attendees.map(\.origin) == [.platform, .synthetic, nil])
    #expect(decoded.attendees == Self.referenceSession().attendees)
  }

  @Test("an attendee table without origin decodes to unknown (old files)")
  func absentAttendeeOriginMeansUnknown() throws {
    // Exactly what encode produced before the field existed.
    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()),
      case .array(let attendees) = table["attendee"]
    else {
      Issue.record("encode did not produce an attendee array")
      return
    }
    let stripped = attendees.map { element -> ConfigValue in
      guard case .table(var attendeeTable) = element else { return element }
      attendeeTable.removeValue(forKey: "origin")
      return .table(attendeeTable)
    }
    table["attendee"] = .array(stripped)

    let decoded = try SessionDescriptorTOML.decode(.table(table))
    #expect(decoded.attendees.allSatisfy { $0.origin == nil })
    // The rest of each row is untouched by the field's absence.
    #expect(decoded.attendees.map(\.id) == ["spaces/x/devices/y", "speaker-1", "speaker-2"])
  }

  @Test("an unrecognised attendee origin is rejected, not guessed")
  func invalidAttendeeOriginIsRejected() throws {
    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()),
      case .array(var attendees) = table["attendee"],
      case .table(var first) = attendees[0]
    else {
      Issue.record("encode did not produce an attendee array")
      return
    }
    first["origin"] = .string("telepathy")
    attendees[0] = .table(first)
    table["attendee"] = .array(attendees)

    #expect(throws: DescriptorTOMLError.self) {
      try SessionDescriptorTOML.decode(.table(table))
    }
  }

  @Test(
    "an identity with only one of platform/external_id is rejected, not silently dropped",
    arguments: ["platform", "external_id"])
  func partialIdentityIsRejected(blankedKey: String) throws {
    // A file carrying half an identity is corrupt, not manual: decoding it to
    // a nil identity would silently break `session.start` idempotency and the
    // default-title comparison for every consumer of the reloaded record.
    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()) else {
      Issue.record("encode did not produce a table")
      return
    }
    table[blankedKey] = .string("")  // the suite's absent sentinel

    #expect(throws: DescriptorTOMLError.invalidField(blankedKey)) {
      try SessionDescriptorTOML.decode(.table(table))
    }
  }

  @Test("a manual session (no identity at all) still decodes to a nil identity")
  func absentIdentityStaysManual() throws {
    var manual = Self.referenceSession()
    manual.identity = nil

    let decoded = try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(manual))
    #expect(decoded.identity == nil)
  }

  @Test("a session.toml without reconciler_version decodes to version 0")
  func absentReconcilerVersionMeansZero() throws {
    // Exactly what encode produced before the field existed: strip it, as an
    // old file on disk simply never carried it.
    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()) else {
      Issue.record("encode did not produce a table")
      return
    }
    table.removeValue(forKey: "reconciler_version")

    let decoded = try SessionDescriptorTOML.decode(.table(table))
    #expect(decoded.reconcilerVersion == 0)
    // The rest of the record is untouched by the field's absence.
    #expect(decoded.speakers == Self.referenceSession().speakers)
  }
}
