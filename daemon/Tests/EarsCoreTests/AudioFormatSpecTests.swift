import Foundation
import Testing

@testable import EarsCore

/// Covers ``AudioFormatSpec``: the `ingest.open` request's `format` payload,
/// matching the literal JSON in `docs/specs/capture-daemon.md`'s "Audio
/// ingestion" example exactly.
@Suite("AudioFormatSpec")
struct AudioFormatSpecTests {
  @Test("decodes the literal spec example")
  func decodesSpecExample() throws {
    let json = """
      {"sample_rate":48000,"channels":1,"encoding":"pcm_s16le"}
      """
    let spec = try JSONDecoder().decode(AudioFormatSpec.self, from: Data(json.utf8))
    #expect(spec == AudioFormatSpec(sampleRate: 48000, channels: 1, encoding: "pcm_s16le"))
  }

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let spec = AudioFormatSpec(sampleRate: 16000, channels: 2, encoding: "pcm_f32le")
    let data = try JSONEncoder().encode(spec)
    let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
    #expect(decoded == spec)
  }
}
