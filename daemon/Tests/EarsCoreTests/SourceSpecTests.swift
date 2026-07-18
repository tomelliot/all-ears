import Foundation
import Testing

@testable import EarsCore

/// Covers ``SourceSpec``: the `sources.add` request payload.
///
/// `docs/specs/capture-daemon.md` gives no literal JSON example for
/// `sources.add` (unlike `ingest.open`'s `format`), so this shape is
/// inferred from `meta.toml`'s fields (`docs/data-formats.md`) — the same
/// properties a runtime-added source ultimately needs recorded. Field names
/// mirror `meta.toml`'s `snake_case` on the wire. Only `id` and `class` are
/// required; everything else is optional so a caller can rely on daemon
/// defaults, matching `sources.add`'s "add ... at runtime" one-line spec.
@Suite("SourceSpec")
struct SourceSpecTests {
  @Test("decodes a minimal spec with only id and class")
  func decodesMinimal() throws {
    let json = """
      {"id":"app:us.zoom.xos","class":"app"}
      """
    let spec = try JSONDecoder().decode(SourceSpec.self, from: Data(json.utf8))
    #expect(spec.id == "app:us.zoom.xos")
    #expect(spec.sourceClass == .app)
    #expect(spec.label == nil)
    #expect(spec.deviceUID == nil)
    #expect(spec.nativeSampleRate == nil)
    #expect(spec.asrSampleRate == nil)
    #expect(spec.storeNative == nil)
    #expect(spec.channels == nil)
    #expect(spec.codec == nil)
    #expect(spec.bitrate == nil)
    #expect(spec.timeCapSeconds == nil)
  }

  @Test("decodes a fully-populated spec with meta.toml-style snake_case keys")
  func decodesFull() throws {
    let json = """
      {
        "id":"app:us.zoom.xos","class":"app","label":"Zoom","device_uid":"",
        "native_sample_rate":48000,"asr_sample_rate":16000,"store_native":true,
        "channels":1,"codec":"aac","bitrate":64000,"time_cap_seconds":7200
      }
      """
    let spec = try JSONDecoder().decode(SourceSpec.self, from: Data(json.utf8))
    #expect(
      spec
        == SourceSpec(
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
          timeCapSeconds: 7200
        ))
  }

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let spec = SourceSpec(id: "mic", sourceClass: .mic, label: "Built-in Mic")
    let data = try JSONEncoder().encode(spec)
    let decoded = try JSONDecoder().decode(SourceSpec.self, from: data)
    #expect(decoded == spec)
  }

  @Test("omits absent optional fields from the encoded JSON")
  func omitsAbsentOptionals() throws {
    let spec = SourceSpec(id: "mic", sourceClass: .mic)
    let data = try JSONEncoder().encode(spec)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?.keys.sorted() == ["class", "id"])
  }
}
