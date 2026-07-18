import Testing

@testable import EarsConfig
@testable import EarsCore

@Suite("EARS_* environment variable layer")
struct EnvironmentLayerTests {
  @Test("a single-segment key becomes a top-level string entry")
  func singleSegmentKey() {
    let layer = configLayer(fromEnvironment: ["EARS_DATA_ROOT": "/custom/root"])
    #expect(layer == .table(["data_root": .string("/custom/root")]))
  }

  @Test("a double-underscore separator nests into a table")
  func doubleUnderscoreNests() {
    let layer = configLayer(fromEnvironment: ["EARS_LOG__LEVEL": "debug"])
    #expect(layer == .table(["log": .table(["level": .string("debug")])]))
  }

  @Test("multiple keys under the same nested table are merged together")
  func multipleNestedKeysMerge() {
    let layer = configLayer(fromEnvironment: [
      "EARS_LOG__LEVEL": "debug",
      "EARS_LOG__OSLOG": "false",
    ])
    #expect(
      layer
        == .table([
          "log": .table([
            "level": .string("debug"),
            "oslog": .bool(false),
          ])
        ])
    )
  }

  @Test("values that look like booleans coerce to ConfigValue.bool")
  func coercesBooleans() {
    #expect(
      configLayer(fromEnvironment: ["EARS_LOG__OSLOG": "true"])
        == .table(["log": .table(["oslog": .bool(true)])]))
    #expect(
      configLayer(fromEnvironment: ["EARS_LOG__OSLOG": "FALSE"])
        == .table(["log": .table(["oslog": .bool(false)])]))
  }

  @Test("values that look like integers coerce to ConfigValue.int")
  func coercesIntegers() {
    let layer = configLayer(fromEnvironment: ["EARS_LOG__ROTATE_MAX_BYTES": "1000"])
    #expect(layer == .table(["log": .table(["rotate_max_bytes": .int(1000)])]))
  }

  @Test("values that look like floating-point numbers coerce to ConfigValue.double")
  func coercesDoubles() {
    let layer = configLayer(fromEnvironment: ["EARS_SOME_RATIO": "3.5"])
    #expect(layer == .table(["some_ratio": .double(3.5)]))
  }

  @Test("values that don't parse as bool/int/double stay strings")
  func nonNumericValuesStayStrings() {
    let layer = configLayer(fromEnvironment: ["EARS_LOG__FORMAT": "auto"])
    #expect(layer == .table(["log": .table(["format": .string("auto")])]))
  }

  @Test("EARS_CONFIG is excluded -- it selects the file, it isn't a config value")
  func earsConfigIsExcluded() {
    let layer = configLayer(fromEnvironment: ["EARS_CONFIG": "/some/path.toml"])
    #expect(layer == .table([:]))
  }

  @Test("non-EARS_-prefixed variables are ignored")
  func nonPrefixedVariablesIgnored() {
    let layer = configLayer(fromEnvironment: ["PATH": "/usr/bin", "HOME": "/home/tom"])
    #expect(layer == .table([:]))
  }

  @Test("an empty environment yields an empty table")
  func emptyEnvironment() {
    #expect(configLayer(fromEnvironment: [:]) == .table([:]))
  }
}
