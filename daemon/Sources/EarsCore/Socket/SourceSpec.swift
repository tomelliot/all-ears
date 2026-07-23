/// The `sources.add` request payload: declares a source to add at runtime.
///
/// `docs/specs/capture-daemon.md` gives no literal JSON example for
/// `sources.add` (unlike `ingest.open`'s `format`), so this shape is
/// inferred from `meta.toml`'s fields (`docs/data-formats.md`) — the same
/// properties a runtime-added source is ultimately recorded with. Field
/// names mirror `meta.toml`'s `snake_case` on the wire. Only ``id`` and
/// ``sourceClass`` are required; everything else is `nil`-able so a caller
/// can rely on daemon-side defaults (matching `sources.add`'s terse
/// one-line spec, "add ... a source at runtime"), and absent optionals are
/// omitted from the encoded JSON rather than sent as explicit `null`.
public struct SourceSpec: Sendable, Hashable, Codable {
  public var id: SourceID
  public var sourceClass: SourceClass
  public var label: String?
  public var deviceUID: String?
  public var nativeSampleRate: Int?
  public var asrSampleRate: Int?
  public var storeNative: Bool?
  public var channels: Int?
  public var codec: String?
  public var bitrate: Int?

  public init(
    id: SourceID,
    sourceClass: SourceClass,
    label: String? = nil,
    deviceUID: String? = nil,
    nativeSampleRate: Int? = nil,
    asrSampleRate: Int? = nil,
    storeNative: Bool? = nil,
    channels: Int? = nil,
    codec: String? = nil,
    bitrate: Int? = nil
  ) {
    self.id = id
    self.sourceClass = sourceClass
    self.label = label
    self.deviceUID = deviceUID
    self.nativeSampleRate = nativeSampleRate
    self.asrSampleRate = asrSampleRate
    self.storeNative = storeNative
    self.channels = channels
    self.codec = codec
    self.bitrate = bitrate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case sourceClass = "class"
    case label
    case deviceUID = "device_uid"
    case nativeSampleRate = "native_sample_rate"
    case asrSampleRate = "asr_sample_rate"
    case storeNative = "store_native"
    case channels
    case codec
    case bitrate
  }
}
