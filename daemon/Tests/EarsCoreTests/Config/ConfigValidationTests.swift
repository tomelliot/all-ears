import Testing

@testable import EarsCore

@Suite("Phase 0 config validation")
struct ConfigValidationTests {
  @Test("the built-in defaults validate cleanly against the Phase 0 schema")
  func defaultsAreValid() {
    let errors = validateConfig(Phase0ConfigSchema.defaults, against: Phase0ConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("a top-level unknown key is reported with its key path")
  func topLevelUnknownKey() {
    let value: ConfigValue = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["bogus": .string("nope")]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPath == ["bogus"])
    #expect(errors.first?.reason == .unknownKey)
    #expect(errors.first?.message == "bogus: unknown key")
  }

  @Test("a nested unknown key under [log] is reported with the full dotted path")
  func nestedUnknownKey() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["log": .table(["bogus": .string("nope")])]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPath == ["log", "bogus"])
    #expect(errors.first?.keyPathString == "log.bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("a top-level type mismatch reports expected vs. actual kind")
  func topLevelTypeMismatch() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["data_root": .int(42)]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPath == ["data_root"])
    #expect(errors.first?.reason == .typeMismatch(expected: .string, got: .int))
    #expect(errors.first?.message == "data_root: expected string, got integer")
  }

  @Test("a nested type mismatch under [log] reports the full dotted path")
  func nestedTypeMismatch() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["log": .table(["oslog": .string("yes")])]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "log.oslog")
    #expect(errors.first?.reason == .typeMismatch(expected: .bool, got: .string))
    #expect(errors.first?.message == "log.oslog: expected bool, got string")
  }

  @Test("a table expected where a scalar was given is itself a type mismatch")
  func tableFieldGivenScalar() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["log": .string("disabled")]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPath == ["log"])
    #expect(errors.first?.reason == .typeMismatch(expected: .table, got: .string))
  }

  @Test("multiple problems are all reported, sorted by key path")
  func multipleErrorsCollected() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table([
        "socket_path": .int(1),
        "log": .table(["level": .int(1), "extra": .bool(true)]),
      ]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.map(\.keyPathString) == ["log.extra", "log.level", "socket_path"])
  }

  @Test(
    "keys from not-yet-implemented sections pass through unvalidated",
    arguments: [
      "earsd", "transcribe", "llm", "cleanup", "summarize", "triggers", "vocab", "schema",
    ]
  )
  func passthroughSectionsAreNotRejected(sectionKey: String) {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table([sectionKey: .table(["anything": .int(1), "whatever": .bool(false)])]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("a passthrough section may also appear as a non-table scalar without being flagged")
  func passthroughSectionAsScalar() {
    let value = mergeConfigLayers([
      Phase0ConfigSchema.defaults,
      .table(["vocab": .string("not-a-table-but-fine")]),
    ])

    let errors = validateConfig(value, against: Phase0ConfigSchema.schema)
    #expect(errors.isEmpty)
  }
}
