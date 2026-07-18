/// Audio format declaration for `ingest.open`, matching
/// `docs/specs/capture-daemon.md`'s literal "Audio ingestion" example
/// exactly:
///
/// ```jsonc
/// {"sample_rate":48000,"channels":1,"encoding":"pcm_s16le"}
/// ```
public struct AudioFormatSpec: Sendable, Hashable, Codable {
  public var sampleRate: Int
  public var channels: Int
  /// PCM sample encoding, e.g. `"pcm_s16le"`.
  public var encoding: String

  public init(sampleRate: Int, channels: Int, encoding: String) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.encoding = encoding
  }

  private enum CodingKeys: String, CodingKey {
    case sampleRate = "sample_rate"
    case channels
    case encoding
  }
}
