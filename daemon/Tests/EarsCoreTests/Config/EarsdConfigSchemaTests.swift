import Testing

@testable import EarsCore

/// Covers `EarsdConfigSchema`'s declared `[earsd]` slice — `docs/configuration.md`'s
/// `[earsd]`, `[earsd.vad]`, and `[[earsd.source]]` tables — and its composition with
/// `Phase0ConfigSchema`'s shared keys into one effective schema for `earsd` callers.
@Suite("EarsdConfigSchema")
struct EarsdConfigSchemaTests {
  @Test("the built-in defaults validate cleanly against the earsd schema")
  func defaultsAreValid() {
    let errors = validateConfig(EarsdConfigSchema.defaults, against: EarsdConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("defaults match the reference config in docs/configuration.md exactly")
  func defaultsMatchReferenceConfig() {
    let vad: ConfigValue = .table([
      "backend": .string("silero"),
      "speech_pad_ms": .int(300),
      "min_silence_ms": .int(700),
    ])
    let ingestWS: ConfigValue = .table([
      "enabled": .bool(false),
      "port": .int(47811),
      "allowed_origins": .array([]),
    ])
    let micSource: ConfigValue = .table([
      "id": .string("mic"),
      "class": .string("mic"),
      "device_uid": .string(""),
    ])
    let earsdTable: ConfigValue = .table([
      "default_time_cap_seconds": .int(7200),
      "hard_total_cap_bytes": .int(0),
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64000),
      "native_sample_rate": .int(48000),
      "asr_sample_rate": .int(16000),
      "store_native": .bool(true),
      "channels": .int(1),
      "vad": vad,
      "ingest_ws": ingestWS,
      "source": .array([micSource]),
    ])
    let triggersTable: ConfigValue = .table([
      "enabled": .bool(false),
      "rule": .array([]),
    ])
    let expected: ConfigValue = .table(["earsd": earsdTable, "triggers": triggersTable])

    #expect(EarsdConfigSchema.defaults == expected)
  }

  @Test("zero-config: the default source list captures only mic, per the Conventions guarantee")
  func zeroConfigCapturesOnlyMic() {
    guard case .table(let root) = EarsdConfigSchema.defaults,
      case .table(let earsd)? = root["earsd"],
      case .array(let sources)? = earsd["source"]
    else {
      Issue.record("expected earsd.source to be an array")
      return
    }
    #expect(sources.count == 1)
    #expect(
      sources.first
        == .table(["id": .string("mic"), "class": .string("mic"), "device_uid": .string("")]))
  }

  @Test("an unknown top-level key under [earsd] is reported with its key path")
  func unknownEarsdKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table(["earsd": .table(["bogus": .int(1)])]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "earsd.bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("an unknown key under [earsd.vad] is reported with the full dotted path")
  func unknownVadKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table(["earsd": .table(["vad": .table(["bogus": .bool(true)])])]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "earsd.vad.bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("an unknown key inside a [[earsd.source]] element is reported with a precise indexed path")
  func unknownSourceElementKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "earsd": .table([
          "source": .array([
            .table(["id": .string("mic"), "class": .string("mic")]),
            .table(["id": .string("system"), "class": .string("system"), "bogus": .bool(true)]),
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "earsd.source[1].bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("a type mismatch inside a [[earsd.source]] element reports the precise indexed path")
  func typeMismatchInSourceElement() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "earsd": .table([
          "source": .array([
            .table(["id": .string("mic"), "class": .string("mic")]),
            .table([
              "id": .string("app:us.zoom.xos"), "class": .string("app"),
              "time_cap_seconds": .string("not-a-number"),
            ]),
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "earsd.source[1].time_cap_seconds")
    #expect(errors.first?.reason == .typeMismatch(expected: .int, got: .string))
  }

  @Test("the doc's full [[earsd.source]] examples (mic, system, app:us.zoom.xos) validate cleanly")
  func fullReferenceSourceListValidates() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "earsd": .table([
          "source": .array([
            .table(["id": .string("mic"), "class": .string("mic"), "device_uid": .string("")]),
            .table(["id": .string("system"), "class": .string("system"), "enabled": .bool(false)]),
            .table([
              "id": .string("app:us.zoom.xos"),
              "class": .string("app"),
              "label": .string("Zoom"),
              "time_cap_seconds": .int(14400),
            ]),
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveSchema composes Phase0's shared keys with earsd's own slice")
  func effectiveSchemaComposesPhase0() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.effectiveDefaults,
      .table(["data_root": .string("/custom/data")]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.effectiveSchema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveSchema still rejects an unknown top-level key")
  func effectiveSchemaRejectsUnknownTopLevelKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.effectiveDefaults,
      .table(["bogus_top_level": .string("nope")]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.effectiveSchema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "bogus_top_level")
  }

  @Test("the doc's [[triggers.rule]] example round-trips through validation")
  func triggersRuleExampleValidates() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "triggers": .table([
          "enabled": .bool(true),
          "rule": .array([
            .table([
              "name": .string("meetings"),
              "on": .string("app-audio-active"),
              "apps": .array([
                .string("us.zoom.xos"), .string("com.microsoft.teams2"), .string("Google Chrome"),
              ]),
              "open_session": .bool(true),
              "sources": .array([.string("mic"), .string("app:us.zoom.xos")]),
              "on_close": .array([.string("transcribe"), .string("cleanup"), .string("summarize")]),
            ])
          ]),
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("an unknown key inside a [[triggers.rule]] element is reported with a precise indexed path")
  func unknownTriggerRuleElementKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "triggers": .table([
          "rule": .array([
            .table(["name": .string("meetings"), "bogus": .bool(true)])
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "triggers.rule[0].bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("an unknown key under [triggers] itself is reported")
  func unknownTriggersKey() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table(["triggers": .table(["bogus": .int(1)])]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "triggers.bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("pre_roll_seconds is a valid int field on a trigger rule")
  func preRollSecondsValidates() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.defaults,
      .table([
        "triggers": .table([
          "rule": .array([
            .table(["name": .string("meetings"), "pre_roll_seconds": .int(15)])
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveSchema still passes through not-yet-implemented sibling sections")
  func effectiveSchemaPassesThroughOtherSections() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.effectiveDefaults,
      .table(["transcribe": .table(["model": .string("parakeet")])]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.effectiveSchema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveDefaults includes both the shared Phase0 keys and the earsd slice")
  func effectiveDefaultsIncludesBoth() {
    guard case .table(let root) = EarsdConfigSchema.effectiveDefaults else {
      Issue.record("expected a table root")
      return
    }
    #expect(root["data_root"] == .string("~/Library/Application Support/ears"))
    #expect(root["earsd"] != nil)
    #expect(root["log"] != nil)
  }
}
