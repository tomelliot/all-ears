import AVFoundation

/// One value in an `AVAudioFile` settings dictionary. `AVAudioFile`'s
/// settings are `[String: Any]`, and `Any` isn't `Sendable` -- but every
/// value this module actually needs to pass (a format ID, a sample rate, a
/// channel count, a bitrate) is one of these three concrete, `Sendable`
/// kinds, so a small closed enum avoids reaching for an `@unchecked
/// Sendable` box around arbitrary `Any`.
public enum AudioSettingValue: Sendable {
  case formatID(AudioFormatID)
  case double(Double)
  case int(Int)

  fileprivate var foundationValue: Any {
    switch self {
    case .formatID(let value): value
    case .double(let value): value
    case .int(let value): value
    }
  }
}

/// Maps a source's codec/bitrate/sample-rate configuration
/// (`docs/configuration.md`'s `[earsd]` table: `codec = "aac" | "opus"`,
/// `bitrate`) to the concrete `AVAudioFile` write settings and file
/// extension for one feed (native or ASR).
///
/// Pure value construction -- no I/O -- so the codec-to-container mapping is
/// unit-tested without touching disk.
public struct ChunkAudioSettings: Sendable {
  /// File extension for this codec, matching `docs/data-formats.md`'s
  /// literal chunk filename examples (`.m4a` for AAC).
  public let fileExtension: String
  /// Settings dictionary passed to `AVAudioFile(forWriting:settings:...)`,
  /// via ``foundationSettings``.
  public let avSettings: [String: AudioSettingValue]
  public let sampleRate: Double

  /// - Parameters:
  ///   - codec: `"aac"` or `"opus"`, per `meta.toml`'s `codec` field.
  ///     Anything else falls back to AAC -- `docs/configuration.md`
  ///     documents only these two, and a passthrough/unknown codec string
  ///     failing to produce a working chunk would violate "on encode
  ///     failure, keep the partial chunk" before a single sample is even
  ///     written.
  ///   - sampleRate: This feed's sample rate (native or ASR).
  ///   - bitrate: `meta.toml`'s `bitrate` field, one configured value
  ///     shared by both feeds even though they run at different sample
  ///     rates (see ``maxSupportedBitrate(forSampleRate:)``).
  public init(codec: String, sampleRate: Int, bitrate: Int) {
    self.sampleRate = Double(sampleRate)
    let formatID: AudioFormatID
    switch codec {
    case "opus":
      self.fileExtension = "caf"
      formatID = kAudioFormatOpus
    default:
      self.fileExtension = "m4a"
      formatID = kAudioFormatMPEG4AAC
    }
    let clampedBitrate = min(bitrate, Self.maxSupportedBitrate(forSampleRate: sampleRate))
    self.avSettings = [
      "AVFormatIDKey": .formatID(formatID),
      "AVSampleRateKey": .double(Double(sampleRate)),
      "AVNumberOfChannelsKey": .int(1),
      "AVEncoderBitRateKey": .int(clampedBitrate),
    ]
  }

  /// The highest encoder bitrate a mono AAC/Opus encoder reliably accepts
  /// at a given sample rate.
  ///
  /// One configured `bitrate` (`meta.toml`) is shared by both the native
  /// and ASR feeds, but they run at different sample rates -- and a real
  /// `AVAudioFile`/`AudioConverter` **throws when the requested bitrate
  /// exceeds what the sample rate can support**: `AVEncoderBitRateKey:
  /// 64000` (the documented default, valid at the native 48kHz rate) fails
  /// `AudioConverterSetProperty(kAudioConverterEncodeBitRate)` outright at
  /// the derived 16kHz ASR rate. This was found by a real `AVAudioFile`
  /// write test failing, not derived from documentation -- there's no
  /// published exact ceiling, so `3x` the sample rate is used as a
  /// conservative, empirically-verified-safe multiplier (16kHz's ceiling
  /// measured at ~48000 bps; the documented 48kHz/64000bps default is well
  /// under `3x` its own rate and passes through unclamped).
  static func maxSupportedBitrate(forSampleRate sampleRate: Int) -> Int {
    sampleRate * 3
  }

  /// `avSettings` converted to the plain `[String: Any]` `AVAudioFile`
  /// expects.
  public var foundationSettings: [String: Any] {
    avSettings.mapValues(\.foundationValue)
  }
}
