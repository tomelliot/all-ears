import EarsConfig
import EarsCore
import EarsDaemonKit
import Foundation

/// Resolves a validated, expanded `earsd` config tree (validated against
/// `EarsdConfigSchema.effectiveSchema`, per `ConfigLoader`'s contract) into
/// the ready-to-run ``EarsDaemonConfiguration`` ``EarsDaemon`` composes from,
/// plus every `[[earsd.source]]` entry this Phase 1 (mic-only) build can't
/// yet capture and therefore leaves out.
///
/// Pure and clock-injected (`now`), so this is fully unit-testable without
/// the filesystem, the real clock, or Core Audio -- the "wiring logic" this
/// task calls out as testable-without-a-live-mic, factored out of `main`
/// exactly so it can be.
///
/// Deliberately never throws: a malformed `[[earsd.source]]` entry (a
/// missing `id`, an unrecognised `class`) is skipped and reported via
/// ``Result/skipped``, matching `docs/specs/capture-daemon.md`'s "missing
/// permission for a source logs an error and disables just that source --
/// never takes down the daemon" policy one layer up, at config-resolution
/// time rather than backend-start time.
enum DaemonConfigResolution {
  /// `docs/data-formats.md`'s current `meta.toml` schema version -- the
  /// value every freshly-resolved ``SourceDescriptor`` is stamped with.
  static let metaSchemaVersion = 1

  /// One `[[earsd.source]]` entry that was not turned into a capture
  /// source, and why -- `earsd`'s normal-run path logs ``reason`` verbatim
  /// per source so an operator can see exactly what was skipped and why.
  struct SkippedSource: Equatable, Sendable {
    var id: String
    var reason: String
  }

  struct Result {
    var configuration: EarsDaemonConfiguration
    var skipped: [SkippedSource]
  }

  static func resolve(config: ConfigValue, now: Instant) -> Result {
    let root = asTable(config)
    let dataRoot = string(root, "data_root", default: "")
    let configuredSocketPath = string(root, "socket_path", default: "")
    let socketPath =
      configuredSocketPath.isEmpty
      ? DefaultSocketPath.resolve(dataRoot: dataRoot) : configuredSocketPath

    let earsd = nestedTable(root, "earsd")
    let chunkSeconds = Double(int(earsd, "chunk_seconds", default: 30))
    let vadTable = nestedTable(earsd, "vad")
    let vad = EnergyVAD(
      speechPadMs: Double(int(vadTable, "speech_pad_ms", default: 300)),
      minSilenceMs: Double(int(vadTable, "min_silence_ms", default: 700))
    )

    let defaults = SourceCaptureDefaults(
      nativeSampleRate: int(earsd, "native_sample_rate", default: 48_000),
      asrSampleRate: int(earsd, "asr_sample_rate", default: 16_000),
      storeNative: bool(earsd, "store_native", default: true),
      channels: int(earsd, "channels", default: 1),
      codec: string(earsd, "codec", default: "aac"),
      bitrate: int(earsd, "bitrate", default: 64_000),
      defaultTimeCapSeconds: int(earsd, "default_time_cap_seconds", default: 7_200)
    )

    var descriptors: [SourceDescriptor] = []
    var skipped: [SkippedSource] = []
    for entry in array(earsd, "source") {
      switch resolveSource(entry, defaults: defaults, now: now) {
      case .included(let descriptor): descriptors.append(descriptor)
      case .skipped(let skip): skipped.append(skip)
      }
    }

    let configuration = EarsDaemonConfiguration(
      sources: descriptors,
      dataRoot: URL(fileURLWithPath: dataRoot.isEmpty ? "." : dataRoot),
      socketPath: socketPath,
      chunkSeconds: chunkSeconds,
      vad: vad,
      codec: defaults.codec,
      bitrate: defaults.bitrate,
      defaultTimeCapSeconds: defaults.defaultTimeCapSeconds,
      ingestWebSocket: resolveIngestWebSocket(earsd)
    )
    return Result(configuration: configuration, skipped: skipped)
  }

  /// `[earsd.ingest_ws]` → ``IngestWebSocketConfiguration``, or `nil` when
  /// `enabled` isn't `true` (the default — opt-in per
  /// `docs/product/browser/prompts/earsd-websocket-ingest.md`).
  private static func resolveIngestWebSocket(
    _ earsd: [String: ConfigValue]
  ) -> IngestWebSocketConfiguration? {
    let table = nestedTable(earsd, "ingest_ws")
    guard bool(table, "enabled", default: false) else { return nil }
    let port = int(table, "port", default: 47_811)
    let origins = stringArray(table, "allowed_origins")
    return IngestWebSocketConfiguration(port: UInt16(clamping: port), allowedOrigins: origins)
  }

  // MARK: - Per-source resolution

  private enum SourceResolution {
    case included(SourceDescriptor)
    case skipped(SkippedSource)
  }

  private struct SourceCaptureDefaults {
    var nativeSampleRate: Int
    var asrSampleRate: Int
    var storeNative: Bool
    var channels: Int
    var codec: String
    var bitrate: Int
    var defaultTimeCapSeconds: Int
  }

  private static func resolveSource(
    _ entry: ConfigValue, defaults: SourceCaptureDefaults, now: Instant
  ) -> SourceResolution {
    guard case .table(let fields) = entry else {
      return .skipped(
        SkippedSource(id: "?", reason: "[[earsd.source]] entry is not a table; skipping"))
    }
    guard case .string(let rawID)? = fields["id"], !rawID.isEmpty else {
      return .skipped(
        SkippedSource(id: "?", reason: "[[earsd.source]] entry has no 'id'; skipping"))
    }
    guard case .string(let rawClass)? = fields["class"] else {
      return .skipped(SkippedSource(id: rawID, reason: "source '\(rawID)' has no 'class'"))
    }
    guard let sourceClass = SourceClass(rawValue: rawClass) else {
      return .skipped(
        SkippedSource(id: rawID, reason: "source '\(rawID)' has unrecognised class '\(rawClass)'")
      )
    }
    if case .bool(false)? = fields["enabled"] {
      return .skipped(SkippedSource(id: rawID, reason: "source '\(rawID)' is disabled in config"))
    }
    guard sourceClass == .mic else {
      return .skipped(
        SkippedSource(
          id: rawID,
          reason:
            "source '\(rawID)' has class '\(rawClass)', which Phase 1 (mic-only capture) doesn't support yet"
        ))
    }

    let label = string(fields, "label", default: "")
    let deviceUID = string(fields, "device_uid", default: "")
    let timeCapSeconds = int(fields, "time_cap_seconds", default: defaults.defaultTimeCapSeconds)

    return .included(
      SourceDescriptor(
        schema: metaSchemaVersion,
        id: SourceID(rawID),
        sourceClass: sourceClass,
        label: label,
        deviceUID: deviceUID,
        nativeSampleRate: defaults.nativeSampleRate,
        asrSampleRate: defaults.asrSampleRate,
        storeNative: defaults.storeNative,
        channels: defaults.channels,
        codec: defaults.codec,
        bitrate: defaults.bitrate,
        timeCapSeconds: timeCapSeconds,
        created: now
      ))
  }

  // MARK: - Small, defaulting (never-throwing) ConfigValue readers
  //
  // `EarsConfig.TOMLFieldReader` is `internal` to that module and throws on
  // a missing/mis-typed field -- the right contract for decoding a
  // known-good `meta.toml`, but not this function's: `resolve(config:now:)`
  // never crashes or fails outright on a malformed `[[earsd.source]]` entry,
  // it skips just that entry, so defaulting reads fit better here than a
  // throwing decoder would.

  private static func asTable(_ value: ConfigValue) -> [String: ConfigValue] {
    guard case .table(let table) = value else { return [:] }
    return table
  }

  private static func nestedTable(_ table: [String: ConfigValue], _ key: String)
    -> [String: ConfigValue]
  {
    guard case .table(let nested)? = table[key] else { return [:] }
    return nested
  }

  private static func array(_ table: [String: ConfigValue], _ key: String) -> [ConfigValue] {
    guard case .array(let items)? = table[key] else { return [] }
    return items
  }

  /// `array(_:_:)` plus filtering to string elements — non-string entries
  /// (a malformed `allowed_origins` entry) are dropped rather than crashing,
  /// matching this function's never-throwing defaulting-reader contract.
  private static func stringArray(_ table: [String: ConfigValue], _ key: String) -> [String] {
    array(table, key).compactMap { value in
      guard case .string(let s) = value else { return nil }
      return s
    }
  }

  private static func string(
    _ table: [String: ConfigValue], _ key: String, default fallback: String
  )
    -> String
  {
    guard case .string(let value)? = table[key] else { return fallback }
    return value
  }

  private static func int(_ table: [String: ConfigValue], _ key: String, default fallback: Int)
    -> Int
  {
    guard case .int(let value)? = table[key] else { return fallback }
    return value
  }

  private static func bool(_ table: [String: ConfigValue], _ key: String, default fallback: Bool)
    -> Bool
  {
    guard case .bool(let value)? = table[key] else { return fallback }
    return value
  }
}
