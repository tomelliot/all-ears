import Testing

@testable import EarsCore

/// Covers ``LineFramer``: turning raw socket-read byte chunks into complete
/// newline-delimited lines, and the inverse (``LineFramer/encodeLine(_:using:)``).
@Suite("LineFramer")
struct LineFramerTests {
  private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
  }

  private func string(_ line: [UInt8]) -> String {
    String(decoding: line, as: UTF8.self)
  }

  @Test("returns no lines for an empty append")
  func emptyAppend() {
    var framer = LineFramer()
    #expect(framer.append([]).isEmpty)
  }

  @Test("returns a single complete line, newline stripped")
  func singleCompleteLine() {
    var framer = LineFramer()
    let lines = framer.append(bytes("{\"cmd\":\"status\"}\n"))
    #expect(lines.map(string) == ["{\"cmd\":\"status\"}"])
  }

  @Test("returns multiple lines delivered in one chunk")
  func multipleLinesInOneChunk() {
    var framer = LineFramer()
    let lines = framer.append(bytes("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"))
    #expect(lines.map(string) == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
  }

  @Test("holds a line split across two appends until the newline arrives")
  func lineSplitAcrossAppends() {
    var framer = LineFramer()
    let first = framer.append(bytes("{\"cmd\":\"stat"))
    #expect(first.isEmpty)
    let second = framer.append(bytes("us\"}\n"))
    #expect(second.map(string) == ["{\"cmd\":\"status\"}"])
  }

  @Test("retains a trailing incomplete fragment after emitting complete lines")
  func retainsTrailingFragment() {
    var framer = LineFramer()
    let lines = framer.append(bytes("{\"a\":1}\n{\"b\":2"))
    #expect(lines.map(string) == ["{\"a\":1}"])
    #expect(framer.pendingFragment == bytes("{\"b\":2"))
    let more = framer.append(bytes("}\n"))
    #expect(more.map(string) == ["{\"b\":2}"])
    #expect(framer.pendingFragment.isEmpty)
  }

  @Test("passes a malformed-JSON line through unchanged rather than validating it")
  func malformedJSONLinePassesThrough() {
    // LineFramer only splits on newlines; it never inspects line contents.
    // A line that isn't valid JSON is still a complete "line" as far as
    // framing is concerned, and is handed to the caller verbatim so the
    // JSON-decoding layer above can decide how to handle it (mirroring
    // IndexLog's skip-and-report precedent) — that decision does not
    // belong to the framer.
    var framer = LineFramer()
    let lines = framer.append(bytes("not even json\n{\"cmd\":\"status\"}\n"))
    #expect(lines.map(string) == ["not even json", "{\"cmd\":\"status\"}"])
  }

  @Test("handles consecutive newlines as an empty line")
  func consecutiveNewlinesYieldEmptyLine() {
    var framer = LineFramer()
    let lines = framer.append(bytes("{\"a\":1}\n\n{\"b\":2}\n"))
    #expect(lines.map(string) == ["{\"a\":1}", "", "{\"b\":2}"])
  }

  @Test("encodes a value as a single newline-terminated JSON line")
  func encodeLineAppendsNewline() throws {
    struct Sample: Encodable { let cmd: String }
    let encoded = try LineFramer.encodeLine(Sample(cmd: "status"))
    #expect(encoded.last == 0x0A)
    let withoutNewline = encoded.dropLast()
    #expect(string(Array(withoutNewline)) == "{\"cmd\":\"status\"}")
  }
}
