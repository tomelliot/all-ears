import EarsConfig
import EarsCore
import EarsDaemonKit
import Foundation

/// Resolves a validated, expanded `earsd` config tree (validated against
/// `EarsdConfigSchema.effectiveSchema`, per `ConfigLoader`'s contract) into
/// the ready-to-run ``EarsDaemonConfiguration`` ``EarsDaemon`` composes from.
/// `mic`/`system`/`app:<bundle-id>` sources are all captured (Phase 4); a
/// `browser:*`/`device:*` entry, or a malformed `system`/`app` id, is
/// skipped and reported via ``Result/skipped`` instead.
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
    /// Non-source config problems resolved leniently (e.g. an invalid
    /// `on_end_stages` entry) — logged verbatim at boot, same policy as
    /// ``skipped``.
    var warnings: [String] = []
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
      bitrate: int(earsd, "bitrate", default: 64_000)
    )

    var descriptors: [SourceDescriptor] = []
    var skipped: [SkippedSource] = []
    for entry in array(earsd, "source") {
      switch resolveSource(entry, defaults: defaults, now: now) {
      case .included(let descriptor): descriptors.append(descriptor)
      case .skipped(let skip): skipped.append(skip)
      }
    }

    let outputRootPath = string(root, "output_root", default: "")

    // `[earsd.sessions].local_sources`: absent defaults to `["mic"]`; an
    // explicit (possibly empty) list is taken verbatim, so `local_sources = []`
    // disables host-audio injection rather than re-defaulting to mic.
    let sessionsTable = nestedTable(earsd, "sessions")
    let browserSessionLocalSources: [SourceID] =
      sessionsTable["local_sources"] == nil
      ? ["mic"]
      : stringArray(sessionsTable, "local_sources").map { SourceID($0) }

    let retentionTable = nestedTable(earsd, "retention")

    // `[earsd.sessions].on_end_stages`: absent defaults to the full chain; an
    // explicit (possibly empty) list is resolved leniently — invalid entries
    // are dropped with a warning, never a boot failure (same policy as
    // malformed sources). `[]` disables the on-end chain.
    let onEndStages: [OnEndStage]
    var warnings: [String] = []
    if sessionsTable["on_end_stages"] == nil {
      onEndStages = OnEndStage.allCases
    } else {
      let resolved = OnEndStage.resolveList(stringArray(sessionsTable, "on_end_stages"))
      onEndStages = resolved.stages
      warnings = resolved.problems
    }

    // `[earsd.sessions].min_words` / `.min_speech_seconds`: the transcript
    // measurements below which the on-end chain stops after transcribe rather
    // than spending the LLM stages on a session that recorded nothing anyone
    // said. Absent defaults to `TranscriptEmptinessPolicy.defaults`; `0`
    // disables that half of the test (both `0` runs the chain unconditionally,
    // as it did before the gate).
    let onEndEmptinessPolicy = TranscriptEmptinessPolicy(
      minWords: int(
        sessionsTable, "min_words", default: TranscriptEmptinessPolicy.defaults.minWords),
      minSpeechSeconds: double(
        sessionsTable, "min_speech_seconds",
        default: TranscriptEmptinessPolicy.defaults.minSpeechSeconds))

    let configuration = EarsDaemonConfiguration(
      sources: descriptors,
      dataRoot: URL(fileURLWithPath: dataRoot.isEmpty ? "." : dataRoot),
      socketPath: socketPath,
      chunkSeconds: chunkSeconds,
      vad: vad,
      codec: defaults.codec,
      bitrate: defaults.bitrate,
      evictionSweepIntervalSeconds: Double(
        int(earsd, "eviction_sweep_interval_s", default: 60)),
      evictAfterTranscriptSeconds: Double(
        int(retentionTable, "evict_after_transcript_seconds", default: 7_200)),
      maxAudioAgeSeconds: Double(
        int(retentionTable, "max_audio_age_seconds", default: 604_800)),
      ingestWebSocket: resolveIngestWebSocket(earsd),
      controlWebSocket: resolveControlWebSocket(earsd),
      sessionIngestCloseGraceSeconds: Double(
        int(sessionsTable, "ingest_close_grace_s", default: 120)),
      sessionRejoinHoldSeconds: Double(int(sessionsTable, "rejoin_hold_s", default: 60)),
      browserSessionLocalSources: browserSessionLocalSources,
      onEndStages: onEndStages,
      onEndEmptinessPolicy: onEndEmptinessPolicy,
      outputRoot: URL(fileURLWithPath: outputRootPath.isEmpty ? "." : outputRootPath)
    )
    return Result(configuration: configuration, skipped: skipped, warnings: warnings)
  }

  /// `[earsd.ingest_ws]` → ``IngestWebSocketConfiguration``, or `nil` when
  /// `enabled` isn't `true` (the default — opt-in per
  /// `docs/specs/capture-daemon.md` ("Audio ingestion")).
  private static func resolveIngestWebSocket(
    _ earsd: [String: ConfigValue]
  ) -> IngestWebSocketConfiguration? {
    let table = nestedTable(earsd, "ingest_ws")
    guard bool(table, "enabled", default: false) else { return nil }
    let port = int(table, "port", default: 47_811)
    let origins = stringArray(table, "allowed_origins")
    return IngestWebSocketConfiguration(port: UInt16(clamping: port), allowedOrigins: origins)
  }

  /// `[earsd.control_ws]` → ``ControlWebSocketConfiguration``, or `nil` when
  /// `enabled` isn't `true` — mirrors ``resolveIngestWebSocket(_:)`` exactly
  /// (opt-in, fail-closed allowlist, distinct default port).
  private static func resolveControlWebSocket(
    _ earsd: [String: ConfigValue]
  ) -> ControlWebSocketConfiguration? {
    let table = nestedTable(earsd, "control_ws")
    guard bool(table, "enabled", default: false) else { return nil }
    let port = int(table, "port", default: 47_812)
    let origins = stringArray(table, "allowed_origins")
    return ControlWebSocketConfiguration(port: UInt16(clamping: port), allowedOrigins: origins)
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
    switch sourceClass {
    case .mic:
      break
    case .system:
      guard rawID == "system" else {
        return .skipped(
          SkippedSource(
            id: rawID,
            reason: "source '\(rawID)' has class 'system' but id must be exactly 'system'")
        )
      }
    case .app:
      guard let detail = SourceID(rawID).detail, !detail.isEmpty else {
        return .skipped(
          SkippedSource(
            id: rawID,
            reason: "source '\(rawID)' has class 'app' but id must be 'app:<bundle-id>'")
        )
      }
    case .browser, .device:
      return .skipped(
        SkippedSource(
          id: rawID,
          reason: "source '\(rawID)' has class '\(rawClass)', which is not yet supported"
        ))
    }

    let label = string(fields, "label", default: "")
    let deviceUID = string(fields, "device_uid", default: "")

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

  /// A floating-point reader that also accepts an integer, matching the
  /// schema's int-satisfies-double widening (`ConfigValueKind.satisfies`):
  /// `min_speech_seconds = 5` and `= 5.0` are the same setting.
  private static func double(
    _ table: [String: ConfigValue], _ key: String, default fallback: Double
  ) -> Double {
    switch table[key] {
    case .double(let value): return value
    case .int(let value): return Double(value)
    default: return fallback
    }
  }
}
