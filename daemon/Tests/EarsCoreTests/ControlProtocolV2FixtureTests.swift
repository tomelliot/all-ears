import Foundation
import Testing

@testable import EarsCore

/// Golden wire fixtures shared with the TypeScript suite
/// (`browser/lib/protocol.test.ts`), loaded from
/// `shared/protocol-fixtures/control-v2.json` at the repo root: every frame
/// is decoded into its typed Swift value and re-encoded, and the re-encoded
/// JSON must equal the fixture byte-for-byte at the JSON-object level — so
/// the Swift and TS codecs can never drift apart without a test noticing.
@Suite("Control protocol v2 golden fixtures")
struct ControlProtocolV2FixtureTests {
  struct Fixtures: Decodable {
    struct Entry: Decodable {
      var name: String
      var frame: JSONValue
    }
    var requests: [Entry]
    var responses: [Entry]
    var events: [Entry]
  }

  /// A JSON tree that survives decode/encode untouched, for object-level
  /// equality against re-encoded frames.
  enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Double.self) {
        self = .number(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([JSONValue].self) {
        self = .array(value)
      } else {
        self = .object(try container.decode([String: JSONValue].self))
      }
    }

    init(data: Data) throws {
      self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
  }

  static func loadFixtures() throws -> Fixtures {
    // <repo>/daemon/Tests/EarsCoreTests/… → <repo>/shared/protocol-fixtures.
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // EarsCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // daemon
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("shared/protocol-fixtures/control-v2.json")
    return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
  }

  private func data(of entry: Fixtures.Entry) throws -> Data {
    // Re-serialize the fixture's parsed tree so both sides of the comparison
    // went through the same JSON printer.
    struct Box: Encodable {
      let value: ControlProtocolV2FixtureTests.JSONValue
      func encode(to encoder: any Encoder) throws {
        try ControlProtocolV2FixtureTests.encode(value, to: encoder)
      }
    }
    return try JSONEncoder().encode(Box(value: entry.frame))
  }

  static func encode(_ value: JSONValue, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case .null: try container.encodeNil()
    case .bool(let bool): try container.encode(bool)
    case .number(let number): try container.encode(number)
    case .string(let string): try container.encode(string)
    case .array(let array):
      try container.encode(array.map { EncodableBox(value: $0) })
    case .object(let object):
      try container.encode(object.mapValues { EncodableBox(value: $0) })
    }
  }

  struct EncodableBox: Encodable {
    let value: JSONValue
    func encode(to encoder: any Encoder) throws {
      try ControlProtocolV2FixtureTests.encode(value, to: encoder)
    }
  }

  @Test("every request fixture decodes and re-encodes to the identical JSON")
  func requestsRoundTrip() throws {
    let fixtures = try Self.loadFixtures()
    #expect(!fixtures.requests.isEmpty)
    for entry in fixtures.requests {
      let raw = try data(of: entry)
      let frame = try JSONDecoder().decode(ControlRequestFrame.self, from: raw)
      let reencoded = try JSONEncoder().encode(frame)
      #expect(
        try JSONValue(data: reencoded) == entry.frame,
        "request fixture '\(entry.name)' drifted")
    }
  }

  @Test("every event fixture decodes and re-encodes to the identical JSON")
  func eventsRoundTrip() throws {
    let fixtures = try Self.loadFixtures()
    #expect(!fixtures.events.isEmpty)
    for entry in fixtures.events {
      let raw = try data(of: entry)
      let frame = try JSONDecoder().decode(EventFrame.self, from: raw)
      let reencoded = try JSONEncoder().encode(frame)
      #expect(
        try JSONValue(data: reencoded) == entry.frame,
        "event fixture '\(entry.name)' drifted")
    }
  }

  @Test("response fixtures decode into the payloads their name declares")
  func responsesDecode() throws {
    let fixtures = try Self.loadFixtures()
    for entry in fixtures.responses {
      let raw = try data(of: entry)
      switch entry.name {
      case "hello-result":
        let frame = try JSONDecoder().decode(
          ControlResponseFrame<HelloResult>.self, from: raw)
        let result = try frame.get()
        #expect(result.protocolVersion == ControlProtocolV2.version)
        #expect(result.capabilities == [.observe, .meetings])
        let reencoded = try JSONEncoder().encode(frame)
        #expect(try JSONValue(data: reencoded) == entry.frame)
      case "meeting-result":
        let frame = try JSONDecoder().decode(ControlResponseFrame<Meeting>.self, from: raw)
        let meeting = try frame.get()
        #expect(meeting.state == .active)
        #expect(meeting.intervals.last?.end == nil)
        let reencoded = try JSONEncoder().encode(frame)
        #expect(try JSONValue(data: reencoded) == entry.frame)
      case "snapshot-result":
        let frame = try JSONDecoder().decode(
          ControlResponseFrame<SnapshotData>.self, from: raw)
        let snapshot = try frame.get()
        #expect(snapshot.rev == 41)
        #expect(snapshot.sources.count == 1)
      case "error-meeting-not-found", "error-hello-required":
        let frame = try JSONDecoder().decode(
          ControlResponseFrame<EmptyData>.self, from: raw)
        #expect(throws: WireError.self) { try frame.get() }
        let reencoded = try JSONEncoder().encode(frame)
        #expect(try JSONValue(data: reencoded) == entry.frame)
      default:
        Issue.record("unknown response fixture '\(entry.name)' — add a decode case for it")
      }
    }
  }
}
