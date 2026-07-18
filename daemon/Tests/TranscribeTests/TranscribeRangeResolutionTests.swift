import EarsCore
import Testing

@testable import transcribe

@Suite("TranscribeRangeResolution")
struct TranscribeRangeResolutionTests {
  private let now = Instant(secondsSinceEpoch: 1_784_284_200)

  @Test("--last 20m resolves to a range ending now, 20 minutes long")
  func lastResolvesRangeEndingNow() {
    let result = TranscribeRangeResolution.resolve(last: "20m", now: now)
    #expect(result == .success(TimeRange(start: now.advanced(by: -1200), end: now)))
  }

  @Test("--last 2h resolves correctly")
  func lastHoursResolves() {
    let result = TranscribeRangeResolution.resolve(last: "2h", now: now)
    #expect(result == .success(TimeRange(start: now.advanced(by: -7200), end: now)))
  }

  @Test("no --last at all is an error naming that no range was specified")
  func noLastIsError() {
    let result = TranscribeRangeResolution.resolve(last: nil, now: now)
    #expect(result == .failure(.noRangeSpecified))
  }

  @Test("a malformed --last value is an error")
  func malformedLastIsError() {
    let result = TranscribeRangeResolution.resolve(last: "not-a-duration", now: now)
    guard case .failure(.invalidDuration(_)) = result else {
      Issue.record("expected .invalidDuration, got \(result)")
      return
    }
  }

  @Test("--last 0m is an error naming the range as empty")
  func zeroLastIsEmptyRangeError() {
    let result = TranscribeRangeResolution.resolve(last: "0m", now: now)
    #expect(result == .failure(.emptyRange))
  }
}
