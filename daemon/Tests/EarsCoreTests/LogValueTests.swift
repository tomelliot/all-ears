import Testing

@testable import EarsCore

@Suite("LogValue")
struct LogValueTests {
  @Test("expressible by string literal")
  func stringLiteral() {
    let value: LogValue = "mic"
    #expect(value == .string("mic"))
  }

  @Test("expressible by integer literal")
  func integerLiteral() {
    let value: LogValue = 16_000
    #expect(value == .int(16_000))
  }

  @Test("expressible by float literal")
  func floatLiteral() {
    let value: LogValue = 0.11
    #expect(value == .double(0.11))
  }

  @Test("expressible by boolean literal")
  func booleanLiteral() {
    let value: LogValue = true
    #expect(value == .bool(true))
  }

  @Test("distinct cases are not equal")
  func distinctCases() {
    #expect(LogValue.string("1") != LogValue.int(1))
  }
}

@Suite("LogField")
struct LogFieldTests {
  @Test("stores an ordered key/value pair")
  func keyValue() {
    let field = LogField("source", "mic")
    #expect(field.key == "source")
    #expect(field.value == .string("mic"))
  }

  @Test("equatable by key and value")
  func equatable() {
    #expect(LogField("frames", 480_000) == LogField("frames", 480_000))
    #expect(LogField("frames", 480_000) != LogField("frames", 1))
    #expect(LogField("a", 1) != LogField("b", 1))
  }
}
