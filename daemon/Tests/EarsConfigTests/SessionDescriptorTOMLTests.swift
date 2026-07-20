import Foundation
import TOMLKit
import Testing

@testable import EarsConfig
@testable import EarsCore

/// Round-trips `SessionDescriptor` through `session.toml` (see
/// `docs/data-formats.md`'s `session.toml` schema), via real temp files --
/// tier-1 per `docs/engineering-practices.md`.
@Suite("SessionDescriptorTOML")
struct SessionDescriptorTOMLTests {
  /// The doc's `session.toml` example, field-for-field (a closed session).
  static let referenceDescriptor = SessionDescriptor(
    schema: 1,
    id: "2026-07-17T10-30-00Z_standup",
    slug: "standup",
    sources: ["mic", "app:us.zoom.xos"],
    start: Instant(secondsSinceEpoch: 1_784_284_200),  // 2026-07-17T10:30:00Z
    end: Instant(secondsSinceEpoch: 1_784_286_120),  // 2026-07-17T11:02:00Z
    state: .closed,
    trigger: .appSignal,
    triggerDetail: "us.zoom.xos",
    vocab: "vocab/2026-07-17T10-30-00Z_standup.txt"
  )

  @Test("encode matches the doc's session.toml example field-for-field")
  func encodeMatchesReferenceExample() {
    let value = SessionDescriptorTOML.encode(Self.referenceDescriptor)
    #expect(
      value
        == .table([
          "schema": .int(1),
          "id": .string("2026-07-17T10-30-00Z_standup"),
          "slug": .string("standup"),
          "sources": .array([.string("mic"), .string("app:us.zoom.xos")]),
          "start": .string("2026-07-17T10:30:00Z"),
          "end": .string("2026-07-17T11:02:00Z"),
          "state": .string("closed"),
          "trigger": .string("app-signal"),
          "trigger_detail": .string("us.zoom.xos"),
          "vocab": .string("vocab/2026-07-17T10-30-00Z_standup.txt"),
          "pre_roll_seconds": .int(0),
          "speakers": .table([:]),
        ])
    )
  }

  @Test("a non-zero preRollSeconds round-trips")
  func preRollSecondsRoundTrips() throws {
    var withPreRoll = Self.referenceDescriptor
    withPreRoll.preRollSeconds = 15
    let text = TOMLBridge.serialize(SessionDescriptorTOML.encode(withPreRoll))
    let table = try TOMLTable(string: text)
    let decoded = try SessionDescriptorTOML.decode(TOMLBridge.configValue(from: table))
    #expect(decoded.preRollSeconds == 15)
  }

  @Test("a session.toml written before pre_roll_seconds existed decodes to 0, not an error")
  func missingPreRollSecondsDefaultsToZero() throws {
    guard case .table(var fields) = SessionDescriptorTOML.encode(Self.referenceDescriptor) else {
      Issue.record("expected a table")
      return
    }
    fields.removeValue(forKey: "pre_roll_seconds")
    let decoded = try SessionDescriptorTOML.decode(.table(fields))
    #expect(decoded.preRollSeconds == 0)
  }

  @Test("decode parses the doc's exact session.toml example back to the model")
  func decodeParsesReferenceExample() throws {
    let table = try TOMLTable(
      string: """
        schema = 1
        id = "2026-07-17T10-30-00Z_standup"
        slug = "standup"
        sources = ["mic", "app:us.zoom.xos"]
        start = "2026-07-17T10:30:00Z"
        end   = "2026-07-17T11:02:00Z"
        state = "closed"
        trigger = "app-signal"
        trigger_detail = "us.zoom.xos"
        vocab = "vocab/2026-07-17T10-30-00Z_standup.txt"
        """
    )
    let value = TOMLBridge.configValue(from: table)
    let descriptor = try SessionDescriptorTOML.decode(value)
    #expect(descriptor == Self.referenceDescriptor)
  }

  @Test("round-trips through a real session.toml file on disk")
  func roundTripsThroughRealFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SessionDescriptorTOMLTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("session.toml")
    let text = TOMLBridge.serialize(SessionDescriptorTOML.encode(Self.referenceDescriptor))
    try text.write(to: fileURL, atomically: true, encoding: .utf8)

    let readBack = try String(contentsOf: fileURL, encoding: .utf8)
    let table = try TOMLTable(string: readBack)
    let decoded = try SessionDescriptorTOML.decode(TOMLBridge.configValue(from: table))

    #expect(decoded == Self.referenceDescriptor)
  }

  @Test("an open session (no end, no trigger_detail, no vocab) round-trips with nils preserved")
  func openSessionRoundTrips() throws {
    let open = SessionDescriptor(
      schema: 1,
      id: "2026-07-17T10-30-00Z_standup",
      slug: "standup",
      sources: ["mic"],
      start: Instant(secondsSinceEpoch: 1_784_284_200),
      end: nil,
      state: .open,
      trigger: .manual,
      triggerDetail: nil,
      vocab: nil
    )

    let text = TOMLBridge.serialize(SessionDescriptorTOML.encode(open))
    let table = try TOMLTable(string: text)
    let decoded = try SessionDescriptorTOML.decode(TOMLBridge.configValue(from: table))

    #expect(decoded == open)
    #expect(decoded.end == nil)
    #expect(decoded.triggerDetail == nil)
    #expect(decoded.vocab == nil)
  }

  @Test("decode throws .missingField when a required key is absent")
  func decodeThrowsOnMissingField() {
    guard case .table(var fields) = SessionDescriptorTOML.encode(Self.referenceDescriptor) else {
      Issue.record("expected a table")
      return
    }
    fields.removeValue(forKey: "slug")

    #expect(throws: DescriptorTOMLError.missingField("slug")) {
      try SessionDescriptorTOML.decode(.table(fields))
    }
  }

  @Test("decode throws .invalidField for an unrecognised state")
  func decodeThrowsOnInvalidState() {
    guard case .table(var fields) = SessionDescriptorTOML.encode(Self.referenceDescriptor) else {
      Issue.record("expected a table")
      return
    }
    fields["state"] = .string("bogus")

    #expect(throws: DescriptorTOMLError.invalidField("state")) {
      try SessionDescriptorTOML.decode(.table(fields))
    }
  }

  @Test("decode throws .invalidField for an unrecognised trigger")
  func decodeThrowsOnInvalidTrigger() {
    guard case .table(var fields) = SessionDescriptorTOML.encode(Self.referenceDescriptor) else {
      Issue.record("expected a table")
      return
    }
    fields["trigger"] = .string("bogus")

    #expect(throws: DescriptorTOMLError.invalidField("trigger")) {
      try SessionDescriptorTOML.decode(.table(fields))
    }
  }

  @Test("decode throws .invalidField for an unparseable start timestamp")
  func decodeThrowsOnInvalidStart() {
    guard case .table(var fields) = SessionDescriptorTOML.encode(Self.referenceDescriptor) else {
      Issue.record("expected a table")
      return
    }
    fields["start"] = .string("not-a-timestamp")

    #expect(throws: DescriptorTOMLError.invalidField("start")) {
      try SessionDescriptorTOML.decode(.table(fields))
    }
  }

  @Test("decode throws .notATable for a non-table root")
  func decodeThrowsOnNonTableRoot() {
    #expect(throws: DescriptorTOMLError.notATable) {
      try SessionDescriptorTOML.decode(.int(1))
    }
  }
}
