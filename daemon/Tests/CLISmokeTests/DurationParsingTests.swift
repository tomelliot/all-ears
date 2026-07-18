import Testing

@testable import ears

@Suite("DurationParsing")
struct DurationParsingTests {
  @Test("plain seconds")
  func plainSeconds() {
    #expect(DurationParsing.seconds(from: "45s") == .success(45))
  }

  @Test("minutes")
  func minutes() {
    #expect(DurationParsing.seconds(from: "30m") == .success(1_800))
  }

  @Test("hours")
  func hours() {
    #expect(DurationParsing.seconds(from: "2h") == .success(7_200))
  }

  @Test("a bare number with no unit suffix is treated as seconds")
  func bareNumber() {
    #expect(DurationParsing.seconds(from: "90") == .success(90))
  }

  @Test("fractional values are honoured")
  func fractional() {
    #expect(DurationParsing.seconds(from: "1.5h") == .success(5_400))
  }

  @Test("empty string fails")
  func empty() {
    #expect(DurationParsing.seconds(from: "") == .failure(.empty))
  }

  @Test(
    "a malformed number fails, naming the offending value", arguments: ["m", "abc", "--5m", "5x"])
  func malformed(_ value: String) {
    #expect(DurationParsing.seconds(from: value) == .failure(.malformed(value)))
  }

  @Test("a negative duration fails")
  func negative() {
    #expect(DurationParsing.seconds(from: "-5m") == .failure(.malformed("-5m")))
  }
}
