import Testing

@testable import EarsConfig
@testable import EarsCore

@Suite("Config path expansion")
struct PathExpansionTests {
  @Test("data_root gets ~ expanded but not resolved against itself")
  func dataRootTildeExpansion() {
    let config: ConfigValue = .table(["data_root": .string("~/Library/Application Support/ears")])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded == .table(["data_root": .string("/Users/tom/Library/Application Support/ears")]))
  }

  @Test("output_root gets ~ expanded but not resolved against data_root")
  func outputRootTildeExpansion() {
    let config: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "output_root": .string("~/Documents/Transcripts"),
    ])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/custom/data"),
          "output_root": .string("/Users/tom/Documents/Transcripts"),
        ]))
  }

  @Test("a relative socket_path resolves against the (expanded) data_root")
  func socketPathResolvesAgainstDataRoot() {
    let config: ConfigValue = .table([
      "data_root": .string("~/data"),
      "socket_path": .string("runtime/earsd.sock"),
    ])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/Users/tom/data"),
          "socket_path": .string("/Users/tom/data/runtime/earsd.sock"),
        ]))
  }

  @Test("an absolute socket_path is left as-is")
  func absoluteSocketPathUnchanged() {
    let config: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "socket_path": .string("/var/run/earsd.sock"),
    ])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/custom/data"),
          "socket_path": .string("/var/run/earsd.sock"),
        ]))
  }

  @Test("an empty socket_path (the derive-it sentinel) is left empty")
  func emptySocketPathUnchanged() {
    let config: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "socket_path": .string(""),
    ])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/custom/data"),
          "socket_path": .string(""),
        ]))
  }

  @Test("log.file resolves relative to data_root, and stays empty when empty")
  func logFileResolution() {
    let withRelativeFile: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "log": .table(["file": .string("logs/tool.jsonl")]),
    ])
    #expect(
      expandConfigPaths(withRelativeFile, homeDirectory: "/Users/tom")
        == .table([
          "data_root": .string("/custom/data"),
          "log": .table(["file": .string("/custom/data/logs/tool.jsonl")]),
        ])
    )

    let withEmptyFile: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "log": .table(["file": .string("")]),
    ])
    #expect(
      expandConfigPaths(withEmptyFile, homeDirectory: "/Users/tom")
        == .table([
          "data_root": .string("/custom/data"),
          "log": .table(["file": .string("")]),
        ])
    )
  }

  @Test("a ~-relative log.file is expanded rather than resolved against data_root")
  func logFileTildeExpansion() {
    let config: ConfigValue = .table([
      "data_root": .string("/custom/data"),
      "log": .table(["file": .string("~/tool.jsonl")]),
    ])
    let expanded = expandConfigPaths(config, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/custom/data"),
          "log": .table(["file": .string("/Users/tom/tool.jsonl")]),
        ]))
  }

  @Test("expanding the Phase 0 defaults against a home directory produces absolute paths")
  func expandsPhase0Defaults() {
    let expanded = expandConfigPaths(Phase0ConfigSchema.defaults, homeDirectory: "/Users/tom")
    #expect(
      expanded
        == .table([
          "data_root": .string("/Users/tom/Library/Application Support/ears"),
          "output_root": .string("/Users/tom/Documents/Transcripts"),
          "socket_path": .string(""),
          "log": .table([
            "level": .string("info"),
            "file": .string(""),
            "format": .string("auto"),
            "oslog": .bool(true),
            "subsystem": .string("net.tomelliot.ears"),
            "rotate_max_bytes": .int(52_428_800),
            "rotate_max_files": .int(5),
          ]),
        ]))
  }
}
