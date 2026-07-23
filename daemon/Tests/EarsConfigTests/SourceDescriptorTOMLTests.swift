import Foundation
import TOMLKit
import Testing

@testable import EarsConfig
@testable import EarsCore

/// Round-trips `SourceDescriptor` through `meta.toml` (see
/// `docs/data-formats.md`'s `meta.toml` schema), via real temp files -- tier-1
/// per `docs/engineering-practices.md`.
@Suite("SourceDescriptorTOML")
struct SourceDescriptorTOMLTests {
  /// The doc's `meta.toml` example, field-for-field.
  static let referenceDescriptor = SourceDescriptor(
    schema: 1,
    id: "app:us.zoom.xos",
    sourceClass: .app,
    label: "Zoom",
    deviceUID: "",
    nativeSampleRate: 48000,
    asrSampleRate: 16000,
    storeNative: true,
    channels: 1,
    codec: "aac",
    bitrate: 64000,
    created: Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z
  )

  @Test("encode matches the doc's meta.toml example field-for-field")
  func encodeMatchesReferenceExample() {
    let value = SourceDescriptorTOML.encode(Self.referenceDescriptor)
    #expect(
      value
        == .table([
          "schema": .int(1),
          "id": .string("app:us.zoom.xos"),
          "class": .string("app"),
          "label": .string("Zoom"),
          "device_uid": .string(""),
          "native_sample_rate": .int(48000),
          "asr_sample_rate": .int(16000),
          "store_native": .bool(true),
          "channels": .int(1),
          "codec": .string("aac"),
          "bitrate": .int(64000),
          "created": .string("2026-07-17T10-30-00Z"),
        ])
    )
  }

  @Test("decode parses the doc's exact meta.toml example back to the model")
  func decodeParsesReferenceExample() throws {
    let table = try TOMLTable(
      string: """
        schema = 1
        id = "app:us.zoom.xos"
        class = "app"
        label = "Zoom"
        device_uid = ""
        native_sample_rate = 48000
        asr_sample_rate = 16000
        store_native = true
        channels = 1
        codec = "aac"
        bitrate = 64000
        created = "2026-07-17T10-30-00Z"
        """
    )
    let value = TOMLBridge.configValue(from: table)
    let descriptor = try SourceDescriptorTOML.decode(value)
    #expect(descriptor == Self.referenceDescriptor)
  }

  @Test("round-trips through a real meta.toml file on disk")
  func roundTripsThroughRealFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SourceDescriptorTOMLTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("meta.toml")
    let text = TOMLBridge.serialize(SourceDescriptorTOML.encode(Self.referenceDescriptor))
    try text.write(to: fileURL, atomically: true, encoding: .utf8)

    let readBack = try String(contentsOf: fileURL, encoding: .utf8)
    let table = try TOMLTable(string: readBack)
    let decoded = try SourceDescriptorTOML.decode(TOMLBridge.configValue(from: table))

    #expect(decoded == Self.referenceDescriptor)
  }

  @Test("the zero-config default mic source round-trips too")
  func zeroConfigMicSourceRoundTrips() throws {
    let mic = SourceDescriptor(
      schema: 1,
      id: "mic",
      sourceClass: .mic,
      label: "",
      deviceUID: "",
      nativeSampleRate: 48000,
      asrSampleRate: 16000,
      storeNative: true,
      channels: 1,
      codec: "aac",
      bitrate: 64000,
      created: Instant(secondsSinceEpoch: 0)
    )

    let text = TOMLBridge.serialize(SourceDescriptorTOML.encode(mic))
    let table = try TOMLTable(string: text)
    let decoded = try SourceDescriptorTOML.decode(TOMLBridge.configValue(from: table))
    #expect(decoded == mic)
  }

  @Test("decode throws .missingField when a required key is absent")
  func decodeThrowsOnMissingField() {
    let value: ConfigValue = .table([
      "schema": .int(1),
      "id": .string("mic"),
      // "class" deliberately omitted
    ])
    #expect(throws: DescriptorTOMLError.missingField("class")) {
      try SourceDescriptorTOML.decode(value)
    }
  }

  @Test("decode throws .invalidField for an unrecognised class")
  func decodeThrowsOnInvalidClass() {
    var table = SourceDescriptorTOML.encode(Self.referenceDescriptor)
    guard case .table(var fields) = table else {
      Issue.record("expected a table")
      return
    }
    fields["class"] = .string("bogus")
    table = .table(fields)

    #expect(throws: DescriptorTOMLError.invalidField("class")) {
      try SourceDescriptorTOML.decode(table)
    }
  }

  @Test("decode throws .invalidField for an unparseable created timestamp")
  func decodeThrowsOnInvalidCreated() {
    var table = SourceDescriptorTOML.encode(Self.referenceDescriptor)
    guard case .table(var fields) = table else {
      Issue.record("expected a table")
      return
    }
    fields["created"] = .string("not-a-timestamp")
    table = .table(fields)

    #expect(throws: DescriptorTOMLError.invalidField("created")) {
      try SourceDescriptorTOML.decode(table)
    }
  }

  @Test("decode throws .notATable for a non-table root")
  func decodeThrowsOnNonTableRoot() {
    #expect(throws: DescriptorTOMLError.notATable) {
      try SourceDescriptorTOML.decode(.string("nope"))
    }
  }
}
