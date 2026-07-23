import Foundation
import Testing

@testable import EarsCore
@testable import earsd

/// Unit tests for ``DaemonConfigResolution``, the pure function that turns a
/// validated, expanded `earsd` config tree (see
/// `EarsdConfigSchema.effectiveSchema`) into the ``EarsDaemonConfiguration``
/// `EarsDaemon` composes from, plus the list of `[[earsd.source]]` entries
/// this Phase 1 (mic-only) build can't yet capture. Pure and clock-injected,
/// so no filesystem, no real clock, no Core Audio, no TCC -- exactly the
/// "wiring logic" this task calls out as testable-without-a-live-mic.
@Suite("DaemonConfigResolution")
struct DaemonConfigResolutionTests {
  private let now = Instant(secondsSinceEpoch: 1_752_000_000)

  private func config(
    dataRoot: String = "/data",
    socketPath: String = "",
    sources: [ConfigValue] = [
      .table(["id": .string("mic"), "class": .string("mic"), "device_uid": .string("")])
    ],
    earsdOverrides: [String: ConfigValue] = [:],
    triggers: ConfigValue? = nil
  ) -> ConfigValue {
    var earsd: [String: ConfigValue] = [
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64_000),
      "native_sample_rate": .int(48_000),
      "asr_sample_rate": .int(16_000),
      "store_native": .bool(true),
      "channels": .int(1),
      "vad": .table(["speech_pad_ms": .int(300), "min_silence_ms": .int(700)]),
      "source": .array(sources),
    ]
    for (key, value) in earsdOverrides { earsd[key] = value }
    var root: [String: ConfigValue] = [
      "data_root": .string(dataRoot),
      "socket_path": .string(socketPath),
      "earsd": .table(earsd),
    ]
    if let triggers { root["triggers"] = triggers }
    return .table(root)
  }

  @Test("resolves the default single mic source into a SourceDescriptor")
  func resolvesDefaultMicSource() throws {
    let result = DaemonConfigResolution.resolve(config: config(), now: now)
    #expect(result.skipped.isEmpty)
    #expect(result.configuration.sources.count == 1)
    let mic = try #require(result.configuration.sources.first)
    #expect(mic.id == "mic")
    #expect(mic.sourceClass == .mic)
    #expect(mic.schema == 1)
    #expect(mic.nativeSampleRate == 48_000)
    #expect(mic.asrSampleRate == 16_000)
    #expect(mic.storeNative == true)
    #expect(mic.channels == 1)
    #expect(mic.codec == "aac")
    #expect(mic.bitrate == 64_000)
    #expect(mic.created == now)
  }

  @Test("carries dataRoot, chunk_seconds, and vad settings through to EarsDaemonConfiguration")
  func carriesDaemonLevelSettings() {
    let result = DaemonConfigResolution.resolve(
      config: config(
        dataRoot: "/custom/data",
        earsdOverrides: ["chunk_seconds": .int(45)]
      ),
      now: now
    )
    #expect(result.configuration.dataRoot == URL(fileURLWithPath: "/custom/data"))
    #expect(result.configuration.chunkSeconds == 45)
    #expect(result.configuration.vad.speechPadMs == 300)
    #expect(result.configuration.vad.minSilenceMs == 700)
  }

  @Test("an empty socket_path resolves to <data_root>/runtime/earsd.sock")
  func emptySocketPathDerivesDefault() {
    let result = DaemonConfigResolution.resolve(
      config: config(dataRoot: "/custom/data", socketPath: ""), now: now)
    #expect(result.configuration.socketPath == "/custom/data/runtime/earsd.sock")
  }

  @Test("a non-empty socket_path is used as-is")
  func explicitSocketPathIsUsedVerbatim() {
    let result = DaemonConfigResolution.resolve(
      config: config(socketPath: "/tmp/custom.sock"), now: now)
    #expect(result.configuration.socketPath == "/tmp/custom.sock")
  }

  @Test("mic/system/app sources are all included; browser/device stay unsupported")
  func systemAndAppSourcesAreIncluded() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("mic"), "class": .string("mic")]),
        .table(["id": .string("system"), "class": .string("system")]),
        .table(["id": .string("app:us.zoom.xos"), "class": .string("app")]),
        .table(["id": .string("browser:meet"), "class": .string("browser")]),
        .table(["id": .string("device:abc"), "class": .string("device")]),
      ]),
      now: now
    )
    #expect(result.configuration.sources.map(\.id) == ["mic", "system", "app:us.zoom.xos"])
    #expect(result.skipped.map(\.id) == ["browser:meet", "device:abc"])
    for skip in result.skipped {
      #expect(skip.reason.contains("not yet supported"))
    }
  }

  @Test("a 'system' source with a non-'system' id is skipped with a precise reason")
  func systemClassWrongIDIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("system2"), "class": .string("system")])
      ]),
      now: now
    )
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.map(\.id) == ["system2"])
    #expect(result.skipped[0].reason.contains("must be exactly 'system'"))
  }

  @Test("an 'app' source with no bundle-id detail is skipped with a precise reason")
  func appClassMissingDetailIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("app"), "class": .string("app")]),
        .table(["id": .string("app:"), "class": .string("app")]),
      ]),
      now: now
    )
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.map(\.id) == ["app", "app:"])
    for skip in result.skipped {
      #expect(skip.reason.contains("app:<bundle-id>"))
    }
  }

  @Test("a source explicitly disabled in config is skipped, not started")
  func disabledSourceIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("mic"), "class": .string("mic"), "enabled": .bool(false)])
      ]),
      now: now
    )
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.map(\.id) == ["mic"])
    #expect(result.skipped[0].reason.contains("disabled"))
  }

  @Test("a source missing 'id' is skipped rather than crashing")
  func missingIDIsSkippedNotCrashed() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [.table(["class": .string("mic")])]), now: now)
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.count == 1)
  }

  @Test("a source with an unrecognised class string is skipped rather than crashing")
  func unrecognisedClassIsSkippedNotCrashed() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("weird"), "class": .string("not-a-real-class")])
      ]),
      now: now
    )
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.map(\.id) == ["weird"])
  }

  @Test("a per-source label and device_uid are carried through")
  func perSourceLabelAndDeviceUID() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table([
          "id": .string("mic"), "class": .string("mic"), "label": .string("Built-in Mic"),
          "device_uid": .string("abc-123"),
        ])
      ]),
      now: now
    )
    let mic = result.configuration.sources.first
    #expect(mic?.label == "Built-in Mic")
    #expect(mic?.deviceUID == "abc-123")
  }

  @Test("zero configured sources resolves cleanly with an empty configuration")
  func zeroSourcesResolvesCleanly() {
    let result = DaemonConfigResolution.resolve(config: config(sources: []), now: now)
    #expect(result.configuration.sources.isEmpty)
    #expect(result.skipped.isEmpty)
  }

  // MARK: - [triggers] / [[triggers.rule]]

  @Test("no [triggers] table resolves to disabled, no rules")
  func triggersDefaultToDisabled() {
    let result = DaemonConfigResolution.resolve(config: config(), now: now)
    #expect(result.configuration.triggers.enabled == false)
    #expect(result.configuration.triggers.rules.isEmpty)
  }

  @Test("the doc's [[triggers.rule]] example resolves into a TriggerRuleConfiguration")
  func triggerRuleExampleResolves() {
    let result = DaemonConfigResolution.resolve(
      config: config(
        triggers: .table([
          "enabled": .bool(true),
          "rule": .array([
            .table([
              "name": .string("meetings"),
              "on": .string("app-audio-active"),
              "apps": .array([.string("us.zoom.xos"), .string("com.microsoft.teams2")]),
              "open_session": .bool(true),
              "sources": .array([.string("mic"), .string("app:us.zoom.xos")]),
              "on_close": .array([.string("transcribe"), .string("cleanup"), .string("summarize")]),
              "pre_roll_seconds": .int(15),
            ])
          ]),
        ])),
      now: now
    )

    #expect(result.configuration.triggers.enabled == true)
    #expect(result.configuration.triggers.rules.count == 1)
    let rule = result.configuration.triggers.rules[0]
    #expect(rule.name == "meetings")
    #expect(rule.on == "app-audio-active")
    #expect(rule.apps == ["us.zoom.xos", "com.microsoft.teams2"])
    #expect(rule.openSession == true)
    #expect(rule.sources == ["mic", "app:us.zoom.xos"])
    #expect(rule.onClose == ["transcribe", "cleanup", "summarize"])
    #expect(rule.preRollSeconds == 15)
  }

  @Test("a trigger rule with no 'sources' is skipped with a precise reason")
  func triggerRuleMissingSourcesIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(
        triggers: .table([
          "rule": .array([
            .table(["name": .string("meetings"), "on": .string("app-audio-active")])
          ])
        ])),
      now: now
    )
    #expect(result.configuration.triggers.rules.isEmpty)
    #expect(result.skippedTriggerRules.map(\.name) == ["meetings"])
    #expect(result.skippedTriggerRules[0].reason.contains("sources"))
  }

  @Test("a trigger rule with no 'name' is skipped rather than crashing")
  func triggerRuleMissingNameIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(
        triggers: .table([
          "rule": .array([.table(["on": .string("app-audio-active")])])
        ])),
      now: now
    )
    #expect(result.configuration.triggers.rules.isEmpty)
    #expect(result.skippedTriggerRules.count == 1)
  }

  @Test("a trigger rule's pre_roll_seconds defaults to 0")
  func triggerRulePreRollDefaultsToZero() {
    let result = DaemonConfigResolution.resolve(
      config: config(
        triggers: .table([
          "rule": .array([
            .table([
              "name": .string("meetings"), "on": .string("app-audio-active"),
              "sources": .array([.string("mic")]),
            ])
          ])
        ])),
      now: now
    )
    #expect(result.configuration.triggers.rules.first?.preRollSeconds == 0)
  }

  @Test("control_ws resolves only when enabled, mirroring ingest_ws (opt-in, fail-closed)")
  func controlWebSocketResolution() throws {
    let disabled = DaemonConfigResolution.resolve(config: config(), now: now)
    #expect(disabled.configuration.controlWebSocket == nil)

    let enabled = DaemonConfigResolution.resolve(
      config: config(
        earsdOverrides: [
          "control_ws": .table([
            "enabled": .bool(true),
            "port": .int(50_000),
            "allowed_origins": .array([.string("chrome-extension://abc")]),
          ])
        ]),
      now: now
    )
    let resolved = try #require(enabled.configuration.controlWebSocket)
    #expect(resolved.port == 50_000)
    #expect(resolved.allowedOrigins == ["chrome-extension://abc"])

    let enabledWithDefaults = DaemonConfigResolution.resolve(
      config: config(earsdOverrides: ["control_ws": .table(["enabled": .bool(true)])]),
      now: now
    )
    let defaulted = try #require(enabledWithDefaults.configuration.controlWebSocket)
    #expect(defaulted.port == 47_812)
    #expect(defaulted.allowedOrigins.isEmpty)
  }

  @Test("browser meeting local_sources defaults to [mic], takes an explicit list, and [] disables")
  func browserMeetingLocalSourcesResolution() {
    let defaulted = DaemonConfigResolution.resolve(config: config(), now: now)
    #expect(defaulted.configuration.browserMeetingLocalSources == ["mic"])

    let custom = DaemonConfigResolution.resolve(
      config: config(
        earsdOverrides: [
          "meetings": .table(["local_sources": .array([.string("mic"), .string("system")])])
        ]),
      now: now)
    #expect(custom.configuration.browserMeetingLocalSources == ["mic", "system"])

    let disabled = DaemonConfigResolution.resolve(
      config: config(earsdOverrides: ["meetings": .table(["local_sources": .array([])])]),
      now: now)
    #expect(disabled.configuration.browserMeetingLocalSources == [])
  }

  @Test("transcribe_on_browser_session_close defaults to true and resolves when disabled")
  func transcribeOnBrowserSessionCloseResolution() {
    let defaulted = DaemonConfigResolution.resolve(config: config(), now: now)
    #expect(defaulted.configuration.triggers.transcribeOnBrowserSessionClose == true)

    let disabled = DaemonConfigResolution.resolve(
      config: config(
        triggers: .table(["transcribe_on_browser_session_close": .bool(false)])),
      now: now
    )
    #expect(disabled.configuration.triggers.transcribeOnBrowserSessionClose == false)
  }
}
