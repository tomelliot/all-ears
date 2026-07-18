import TOMLKit
import Testing

@testable import EarsConfig
@testable import EarsCore

@Suite("TOMLKit <-> ConfigValue bridge")
struct TOMLBridgeTests {
  @Test("converts scalar TOML values to their ConfigValue equivalents")
  func convertsScalars() throws {
    let table = try TOMLTable(
      string: """
        string_value = "hello"
        int_value = 42
        double_value = 3.5
        bool_value = true
        """
    )

    let value = TOMLBridge.configValue(from: table)
    #expect(
      value
        == .table([
          "string_value": .string("hello"),
          "int_value": .int(42),
          "double_value": .double(3.5),
          "bool_value": .bool(true),
        ])
    )
  }

  @Test("converts nested tables and arrays")
  func convertsNestedTablesAndArrays() throws {
    let table = try TOMLTable(
      string: """
        tags = ["a", "b", "c"]

        [log]
        level = "debug"
        rotate_max_files = 5
        """
    )

    let value = TOMLBridge.configValue(from: table)
    #expect(
      value
        == .table([
          "log": .table([
            "level": .string("debug"),
            "rotate_max_files": .int(5),
          ]),
          "tags": .array([.string("a"), .string("b"), .string("c")]),
        ])
    )
  }

  @Test("serializes a ConfigValue tree back to parseable TOML text")
  func serializeRoundTrips() throws {
    let original: ConfigValue = .table([
      "data_root": .string("/tmp/ears"),
      "log": .table([
        "level": .string("info"),
        "oslog": .bool(true),
        "rotate_max_bytes": .int(52_428_800),
      ]),
    ])

    let text = TOMLBridge.serialize(original)
    let reparsed = TOMLBridge.configValue(from: try TOMLTable(string: text))
    #expect(reparsed == original)
  }

  @Test("serializing a non-table value yields an empty document")
  func serializeNonTableYieldsEmptyString() {
    #expect(TOMLBridge.serialize(.string("not a table")) == "")
  }
}
