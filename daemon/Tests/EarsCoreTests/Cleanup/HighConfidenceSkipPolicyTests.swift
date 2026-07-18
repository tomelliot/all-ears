import Testing

@testable import EarsCore

@Suite("HighConfidenceSkipPolicy")
struct HighConfidenceSkipPolicyTests {
  let policy = HighConfidenceSkipPolicy()

  @Test("skips a segment at or above the confidence threshold")
  func skipsHighConfidence() {
    let segment = Segment(start: 0, end: 1, text: "Nothing from me.", confidence: 0.97)
    #expect(policy.shouldSkip(segment))
  }

  @Test("does not skip a segment below the confidence threshold")
  func doesNotSkipLowConfidence() {
    let segment = Segment(start: 0, end: 1, text: "Nothing from me.", confidence: 0.6)
    #expect(!policy.shouldSkip(segment))
  }

  @Test("does not skip a segment with no reported confidence")
  func doesNotSkipUnknownConfidence() {
    let segment = Segment(start: 0, end: 1, text: "Nothing from me.", confidence: nil)
    #expect(!policy.shouldSkip(segment))
  }

  @Test("threshold is configurable")
  func configurableThreshold() {
    let lenient = HighConfidenceSkipPolicy(minConfidence: 0.5)
    let segment = Segment(start: 0, end: 1, text: "Nothing from me.", confidence: 0.6)
    #expect(lenient.shouldSkip(segment))
  }

  @Test("exactly at the threshold counts as high confidence")
  func exactlyAtThreshold() {
    let segment = Segment(
      start: 0, end: 1, text: "Nothing from me.", confidence: policy.minConfidence)
    #expect(policy.shouldSkip(segment))
  }
}
