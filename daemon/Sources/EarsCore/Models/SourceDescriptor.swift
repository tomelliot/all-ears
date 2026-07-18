/// A source's on-disk descriptor, mirroring `meta.toml` (see `docs/data-formats.md`).
///
/// This is the pure model; mapping to and from the TOML file (including the
/// ISO-8601 rendering of ``created``) belongs to `EarsConfig`. Field names follow
/// Swift conventions; the TOML mapper bridges the `snake_case` keys.
public struct SourceDescriptor: Sendable, Hashable, Codable {
  /// Schema version of the `meta.toml` format this descriptor was read from.
  public var schema: Int
  public var id: SourceID
  public var sourceClass: SourceClass
  public var label: String
  /// Device UID for `device`/`mic` sources; empty otherwise.
  public var deviceUID: String
  /// Sample rate of the listenable `chunks/` feed (Hz).
  public var nativeSampleRate: Int
  /// Sample rate of the derived `asr/` feed the transcriber consumes (Hz).
  public var asrSampleRate: Int
  /// Whether the native-rate listenable copy is retained (`false` => ASR feed only).
  public var storeNative: Bool
  public var channels: Int
  public var codec: String
  public var bitrate: Int
  /// This source's ring-buffer window in seconds (default 7200 = 2 h).
  public var timeCapSeconds: Int
  public var created: Instant

  public init(
    schema: Int,
    id: SourceID,
    sourceClass: SourceClass,
    label: String,
    deviceUID: String = "",
    nativeSampleRate: Int,
    asrSampleRate: Int,
    storeNative: Bool,
    channels: Int,
    codec: String,
    bitrate: Int,
    timeCapSeconds: Int,
    created: Instant
  ) {
    self.schema = schema
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
    self.timeCapSeconds = timeCapSeconds
    self.created = created
  }
}
