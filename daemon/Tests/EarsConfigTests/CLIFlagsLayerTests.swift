import Testing

@testable import EarsConfig
@testable import EarsCore

/// Covers ``configLayer(fromCLIFlags:)``: the highest-precedence layer in
/// `docs/configuration.md`'s model, built from the `--log-level`/`--log-file`
/// flags every tool supports (see `docs/configuration.md`'s "CLI flags"
/// layer and `EarsCLI`'s use of this as `ConfigLoadInputs.flags`).
@Suite("CLI flags layer")
struct CLIFlagsLayerTests {
  @Test("no flags passed yields an empty table, so lower layers are untouched")
  func noFlags() {
    let layer = configLayer(fromCLIFlags: CLILogFlags())
    #expect(layer == .table([:]))
  }

  @Test("--log-level becomes log.level")
  func logLevelOnly() {
    let layer = configLayer(fromCLIFlags: CLILogFlags(level: "debug"))
    #expect(layer == .table(["log": .table(["level": .string("debug")])]))
  }

  @Test("--log-file becomes log.file")
  func logFileOnly() {
    let layer = configLayer(fromCLIFlags: CLILogFlags(file: "/tmp/earsd.jsonl"))
    #expect(layer == .table(["log": .table(["file": .string("/tmp/earsd.jsonl")])]))
  }

  @Test("both flags nest together under one log table")
  func bothFlags() {
    let layer = configLayer(fromCLIFlags: CLILogFlags(level: "error", file: "/tmp/earsd.jsonl"))
    #expect(
      layer
        == .table([
          "log": .table([
            "level": .string("error"),
            "file": .string("/tmp/earsd.jsonl"),
          ])
        ])
    )
  }
}
