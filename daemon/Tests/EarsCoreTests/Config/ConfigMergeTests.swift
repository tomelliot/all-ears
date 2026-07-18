import Testing

@testable import EarsCore

@Suite("Config layer merging")
struct ConfigMergeTests {
  @Test("a single layer merges to itself")
  func singleLayer() {
    let layer: ConfigValue = .table(["data_root": .string("/tmp/a")])
    #expect(mergeConfigLayers([layer]) == layer)
  }

  @Test("a later layer overrides an earlier layer at the same key")
  func laterLayerOverrides() {
    let defaults: ConfigValue = .table(["data_root": .string("defaults-root")])
    let file: ConfigValue = .table(["data_root": .string("file-root")])
    let merged = mergeConfigLayers([defaults, file])
    #expect(merged == .table(["data_root": .string("file-root")]))
  }

  @Test("every later layer overrides the ones before it, in order")
  func fullPrecedenceChain() {
    let defaults: ConfigValue = .table(["data_root": .string("defaults")])
    let file: ConfigValue = .table(["data_root": .string("file")])
    let env: ConfigValue = .table(["data_root": .string("env")])
    let flags: ConfigValue = .table(["data_root": .string("flags")])

    #expect(
      mergeConfigLayers([defaults, file, env, flags]) == .table(["data_root": .string("flags")]))
    #expect(mergeConfigLayers([defaults, file, env]) == .table(["data_root": .string("env")]))
    #expect(mergeConfigLayers([defaults, file]) == .table(["data_root": .string("file")]))
  }

  @Test("a missing key in a later layer falls through to the earlier layer's value")
  func missingKeyUsesEarlierLayer() {
    let defaults: ConfigValue = .table([
      "data_root": .string("defaults-root"),
      "output_root": .string("defaults-output"),
    ])
    let file: ConfigValue = .table(["data_root": .string("file-root")])

    let merged = mergeConfigLayers([defaults, file])
    #expect(
      merged
        == .table([
          "data_root": .string("file-root"),
          "output_root": .string("defaults-output"),
        ]))
  }

  @Test("nested tables merge key-wise, preserving untouched sibling keys")
  func nestedTableMerge() {
    let defaults: ConfigValue = .table([
      "log": .table([
        "level": .string("info"),
        "format": .string("auto"),
        "oslog": .bool(true),
      ])
    ])
    let file: ConfigValue = .table([
      "log": .table([
        "level": .string("debug")
      ])
    ])

    let merged = mergeConfigLayers([defaults, file])
    #expect(
      merged
        == .table([
          "log": .table([
            "level": .string("debug"),
            "format": .string("auto"),
            "oslog": .bool(true),
          ])
        ]))
  }

  @Test("a non-table overlay value replaces a table base value outright")
  func nonTableOverlayReplacesTable() {
    let base: ConfigValue = .table(["log": .table(["level": .string("info")])])
    let overlay: ConfigValue = .table(["log": .string("disabled")])

    let merged = mergeConfigValues(base: base, overlay: overlay)
    #expect(merged == .table(["log": .string("disabled")]))
  }

  @Test("merging zero layers yields an empty table")
  func zeroLayers() {
    #expect(mergeConfigLayers([]) == .table([:]))
  }
}
