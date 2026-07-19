import Testing

@testable import EarsCore

/// Covers `LLMStagesConfigSchema`'s declared `[llm]`/`[cleanup]`/
/// `[[summarize.preset]]`/`[vocab]` slices — previously bare, unvalidated
/// passthrough keys per `Phase0ConfigSchema`'s doc comment — and their
/// composition into one effective schema for `cleanup`/`summarize`.
@Suite("LLMStagesConfigSchema")
struct LLMStagesConfigSchemaTests {
  @Test("the built-in defaults validate cleanly against the schema")
  func defaultsAreValid() {
    let errors = validateConfig(
      LLMStagesConfigSchema.defaults, against: LLMStagesConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("defaults match the reference config in docs/configuration.md")
  func defaultsMatchReferenceConfig() {
    let expected: ConfigValue = .table([
      "llm": .table([
        "backend": .string("llm-cli"),
        "model": .string(""),
        "command": .string(""),
      ]),
      "cleanup": .table([
        "prompt_file": .string(""),
        "use_vocab": .bool(true),
      ]),
      "summarize": .table([
        "preset": .array([])
      ]),
      "vocab": .table([
        "global": .string("")
      ]),
    ])
    #expect(LLMStagesConfigSchema.defaults == expected)
  }

  @Test("a [[summarize.preset]] block round-trips through validation")
  func summarizePresetsRoundTrip() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.defaults,
      .table([
        "summarize": .table([
          "preset": .array([
            .table(["name": .string("brief"), "prompt_file": .string("prompts/brief.md")]),
            .table(["name": .string("actions"), "prompt_file": .string("prompts/action-items.md")]),
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test(
    "an unknown key inside a [[summarize.preset]] element is reported with a precise indexed path")
  func unknownPresetElementKey() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.defaults,
      .table([
        "summarize": .table([
          "preset": .array([
            .table(["name": .string("brief"), "prompt_file": .string("x"), "bogus": .bool(true)])
          ])
        ])
      ]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "summarize.preset[0].bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("an unknown top-level key under [llm] is reported")
  func unknownLLMKey() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.defaults,
      .table(["llm": .table(["bogus": .int(1)])]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "llm.bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("the doc's [llm]/[cleanup]/[vocab] reference example validates cleanly")
  func fullReferenceExampleValidates() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.defaults,
      .table([
        "llm": .table([
          "backend": .string("llm-cli"),
          "model": .string("claude-sonnet-5"),
        ]),
        "cleanup": .table([
          "prompt_file": .string(""),
          "use_vocab": .bool(true),
        ]),
        "vocab": .table([
          "global": .string("vocab/global.txt")
        ]),
      ]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveSchema composes Phase0's shared keys with this schema's own slices")
  func effectiveSchemaComposesPhase0() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.effectiveDefaults,
      .table(["data_root": .string("/custom/data")]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.effectiveSchema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveSchema still passes through not-yet-implemented sibling sections")
  func effectiveSchemaPassesThroughOtherSections() {
    let value = mergeConfigLayers([
      LLMStagesConfigSchema.effectiveDefaults,
      .table(["earsd": .table(["chunk_seconds": .int(30)])]),
    ])

    let errors = validateConfig(value, against: LLMStagesConfigSchema.effectiveSchema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveDefaults includes both the shared Phase0 keys and this schema's slices")
  func effectiveDefaultsIncludesBoth() {
    guard case .table(let root) = LLMStagesConfigSchema.effectiveDefaults else {
      Issue.record("expected a table root")
      return
    }
    #expect(root["data_root"] == .string("~/Library/Application Support/ears"))
    #expect(root["llm"] != nil)
    #expect(root["cleanup"] != nil)
    #expect(root["summarize"] != nil)
    #expect(root["vocab"] != nil)
    #expect(root["log"] != nil)
  }
}
