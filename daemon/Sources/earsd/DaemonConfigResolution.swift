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

  /// One `[[triggers.rule]]` entry that was not turned into a
  /// ``TriggerRuleConfiguration``, and why -- reported the same way a
  /// malformed `[[earsd.source]]` entry is, at config-resolution time rather
  /// than deep inside the trigger observer.
  struct SkippedTriggerRule: Equatable, Sendable {
    var name: String
    var reason: String
  }

  struct Result {
    var configuration: EarsDaemonConfiguration
    var skipped: [SkippedSource]
    var skippedTriggerRules: [SkippedTriggerRule] = []
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

    let (triggers, skippedTriggerRules) = resolveTriggers(root)
    let outputRootPath = string(root, "output_root", default: "")

    // `[earsd.meetings].local_sources`: absent defaults to `["mic"]`; an
    // explicit (possibly empty) list is taken verbatim, so `local_sources = []`
    // disables host-audio injection rather than re-defaulting to mic.
    let meetingsTable = nestedTable(earsd, "meetings")
    let browserMeetingLocalSources: [SourceID] =
      meetingsTable["local_sources"] == nil
      ? ["mic"]
      : stringArray(meetingsTable, "local_sources").map { SourceID($0) }

    let retentionTable = nestedTable(earsd, "retention")

    let configuration = EarsDaemonConfiguration(
      sources: descriptors,
      dataRoot: URL(fileURLWithPath: dataRoot.isEmpty ? "." : dataRoot),
      socketPath: socketPath,
      chunkSeconds: chunkSeconds,
      vad: vad,
      codec: defaults.codec,
      bitrate: defaults.bitrate,
      defaultTimeCapSeconds: defaults.defaultTimeCapSeconds,
      evictionSweepIntervalSeconds: Double(
        int(earsd, "eviction_sweep_interval_s", default: 60)),
      evictAfterTranscriptSeconds: Double(
        int(retentionTable, "evict_after_transcript_seconds", default: 7_200)),
      maxAudioAgeSeconds: Double(
        int(retentionTable, "max_audio_age_seconds", default: 604_800)),
      ingestWebSocket: resolveIngestWebSocket(earsd),
      controlWebSocket: resolveControlWebSocket(earsd),
      meetingIngestCloseGraceSeconds: Double(
        int(meetingsTable, "ingest_close_grace_s", default: 120)),
      browserMeetingLocalSources: browserMeetingLocalSources,
      triggers: triggers,
      outputRoot: URL(fileURLWithPath: outputRootPath.isEmpty ? "." : outputRootPath)
    )
    return Result(
      configuration: configuration, skipped: skipped, skippedTriggerRules: skippedTriggerRules)
  }

  // MARK: - [triggers] / [[triggers.rule]] resolution

  private static func resolveTriggers(_ root: [String: ConfigValue])
    -> (TriggersConfiguration, [SkippedTriggerRule])
  {
    let triggersTable = nestedTable(root, "triggers")
    let enabled = bool(triggersTable, "enabled", default: false)
    let transcribeOnBrowserClose = bool(
      triggersTable, "transcribe_on_browser_session_close", default: true)

    var rules: [TriggerRuleConfiguration] = []
    var skipped: [SkippedTriggerRule] = []
    for entry in array(triggersTable, "rule") {
      switch resolveTriggerRule(entry) {
      case .included(let rule): rules.append(rule)
      case .skipped(let skip): skipped.append(skip)
      }
    }
    return (
      TriggersConfiguration(
        enabled: enabled, rules: rules,
        transcribeOnBrowserSessionClose: transcribeOnBrowserClose),
      skipped
    )
  }

  private enum TriggerRuleResolution {
    case included(TriggerRuleConfiguration)
    case skipped(SkippedTriggerRule)
  }

  /// Never-throwing, matching ``resolveSource(_:defaults:now:)``'s own
  /// contract: a malformed `[[triggers.rule]]` entry is skipped and
  /// reported, not a fatal config error.
  private static func resolveTriggerRule(_ entry: ConfigValue) -> TriggerRuleResolution {
    guard case .table(let fields) = entry else {
      return .skipped(
        SkippedTriggerRule(name: "?", reason: "[[triggers.rule]] entry is not a table"))
    }
    guard case .string(let name)? = fields["name"], !name.isEmpty else {
      return .skipped(
        SkippedTriggerRule(name: "?", reason: "[[triggers.rule]] entry has no 'name'"))
    }
    let on = string(fields, "on", default: "")
    guard !on.isEmpty else {
      return .skipped(SkippedTriggerRule(name: name, reason: "trigger rule '\(name)' has no 'on'"))
    }
    let sources = stringArray(fields, "sources").map { SourceID($0) }
    guard !sources.isEmpty else {
      return .skipped(
        SkippedTriggerRule(name: name, reason: "trigger rule '\(name)' has no 'sources'"))
    }

    return .included(
      TriggerRuleConfiguration(
        name: name,
        on: on,
        apps: stringArray(fields, "apps"),
        openSession: bool(fields, "open_session", default: true),
        sources: sources,
        onClose: stringArray(fields, "on_close"),
        preRollSeconds: int(fields, "pre_roll_seconds", default: 0)
      ))
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
