import Testing

@testable import EarsCore

/// Covers ``DefaultLogFilePath/resolve(dataRoot:tool:)``: the fallback JSON
/// Lines log path `docs/logging.md`'s output-sink precedence uses when
/// `[log].file` is empty (flag, env, and config-file layers all unset).
@Suite("DefaultLogFilePath")
struct DefaultLogFilePathTests {
  @Test("joins data root and tool name under logs/, as <tool>.jsonl")
  func joinsDataRootAndTool() {
    let path = DefaultLogFilePath.resolve(
      dataRoot: "/Users/tom/Library/Application Support/ears",
      tool: "earsd"
    )
    #expect(path == "/Users/tom/Library/Application Support/ears/logs/earsd.jsonl")
  }

  @Test("tolerates a trailing slash on data root without doubling it")
  func tolersTrailingSlash() {
    let path = DefaultLogFilePath.resolve(dataRoot: "/data/", tool: "transcribe")
    #expect(path == "/data/logs/transcribe.jsonl")
  }

  @Test("uses the given tool name verbatim for the file's base name")
  func usesToolName() {
    #expect(
      DefaultLogFilePath.resolve(dataRoot: "/data", tool: "cleanup") == "/data/logs/cleanup.jsonl")
    #expect(
      DefaultLogFilePath.resolve(dataRoot: "/data", tool: "summarize")
        == "/data/logs/summarize.jsonl")
  }
}
