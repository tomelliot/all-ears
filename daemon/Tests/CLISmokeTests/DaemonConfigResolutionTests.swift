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
    earsdOverrides: [String: ConfigValue] = [:]
  ) -> ConfigValue {
    var earsd: [String: ConfigValue] = [
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64_000),
      "native_sample_rate": .int(48_000),
      "asr_sample_rate": .int(16_000),
      "store_native": .bool(true),
      "channels": .int(1),
      "default_time_cap_seconds": .int(7_200),
      "vad": .table(["speech_pad_ms": .int(300), "min_silence_ms": .int(700)]),
      "source": .array(sources),
    ]
    for (key, value) in earsdOverrides { earsd[key] = value }
    return .table([
      "data_root": .string(dataRoot),
      "socket_path": .string(socketPath),
      "earsd": .table(earsd),
    ])
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
    #expect(mic.timeCapSeconds == 7_200)
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

  @Test("a non-mic source class is skipped, logged, and excluded from the daemon configuration")
  func nonMicClassIsSkipped() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table(["id": .string("mic"), "class": .string("mic")]),
        .table(["id": .string("system"), "class": .string("system")]),
        .table(["id": .string("app:us.zoom.xos"), "class": .string("app")]),
      ]),
      now: now
    )
    #expect(result.configuration.sources.map(\.id) == ["mic"])
    #expect(result.skipped.map(\.id) == ["system", "app:us.zoom.xos"])
    for skip in result.skipped {
      #expect(skip.reason.contains("Phase 1"))
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

  @Test("a per-source time_cap_seconds override wins over the [earsd] default")
  func perSourceTimeCapOverride() {
    let result = DaemonConfigResolution.resolve(
      config: config(sources: [
        .table([
          "id": .string("mic"), "class": .string("mic"), "time_cap_seconds": .int(3_600),
        ])
      ]),
      now: now
    )
    #expect(result.configuration.sources.first?.timeCapSeconds == 3_600)
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
}
