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
    let controlWS: ConfigValue = .table([
      "enabled": .bool(false),
      "port": .int(47812),
      "allowed_origins": .array([]),
    ])
    let micSource: ConfigValue = .table([
      "id": .string("mic"),
      "class": .string("mic"),
      "device_uid": .string(""),
    ])
    let earsdTable: ConfigValue = .table([
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64000),
      "native_sample_rate": .int(48000),
      "asr_sample_rate": .int(16000),
      "store_native": .bool(true),
      "channels": .int(1),
      "vad": vad,
      "sessions": .table([
        "ingest_close_grace_s": .int(120),
        "rejoin_hold_s": .int(60),
        "local_sources": .array([.string("mic")]),
        "on_end_stages": .array([
          .string("transcribe"), .string("cleanup"), .string("summarize"),
        ]),
      ]),
      "retention": .table([
        "evict_after_transcript_seconds": .int(7200),
        "max_audio_age_seconds": .int(604800),
      ]),
      "ingest_ws": ingestWS,
      "control_ws": controlWS,
      "source": .array([micSource]),
    ])
    let expected: ConfigValue = .table(["earsd": earsdTable])

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
              "enabled": .string("not-a-bool"),
            ]),
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "earsd.source[1].enabled")
    #expect(errors.first?.reason == .typeMismatch(expected: .bool, got: .string))
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

  @Test("a leftover [triggers] table is rejected as unknown, not silently ignored (#42)")
  func triggersTableIsRejected() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.effectiveDefaults,
      .table(["triggers": .table(["enabled": .bool(true)])]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.effectiveSchema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "triggers")
    #expect(errors.first?.reason == .unknownKey)
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

  @Test("the empty-transcript thresholds validate, as an integer or a float")
  func emptinessThresholdsValidate() {
    for speech in [ConfigValue.double(5.0), .double(0.5), .int(5), .int(0)] {
      let value = mergeConfigLayers([
        EarsdConfigSchema.effectiveDefaults,
        .table([
          "earsd": .table([
            "sessions": .table(["min_words": .int(10), "min_speech_seconds": speech])
          ])
        ]),
      ])
      #expect(validateConfig(value, against: EarsdConfigSchema.effectiveSchema).isEmpty)
    }
  }

  @Test("a mistyped threshold is a reported config error, not a silent fallback")
  func mistypedThresholdIsRejected() {
    let value = mergeConfigLayers([
      EarsdConfigSchema.effectiveDefaults,
      .table([
        "earsd": .table([
          "sessions": .table(["min_words": .string("ten"), "min_speech_seconds": .bool(true)])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: EarsdConfigSchema.effectiveSchema)
    #expect(
      errors.map(\.keyPathString) == [
        "earsd.sessions.min_speech_seconds", "earsd.sessions.min_words",
      ])
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
