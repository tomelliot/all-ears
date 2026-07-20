import Testing

@testable import EarsCore

/// Covers ``NaturalPauseSegmenter``: turning ``RangeReconstructor``'s VAD
/// spans for a requested range into the sequence of speech-bearing windows
/// `docs/specs/transcribe.md` describes -- "segment at natural
/// pauses, not fixed cuts", plus silence-skipping (no window at all for a
/// stretch with no VAD-flagged speech) and a short pre-roll before each
/// utterance onset.
@Suite("NaturalPauseSegmenter")
struct NaturalPauseSegmenterTests {
  private let options = SegmentationOptions(maxPauseSeconds: 1.5, preRollSeconds: 0.3)

  @Test("no VAD spans at all yields no segments")
  func noSpansYieldsNoSegments() {
    let windows = NaturalPauseSegmenter.segments(vadSpans: [], rangeDuration: 30, options: options)
    #expect(windows.isEmpty)
  }

  @Test("silence-only spans (no speech) yield no segments -- silence-skipping")
  func silenceOnlyYieldsNoSegments() {
    let spans = [VADSpan(state: .silence, start: 0, end: 30)]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows.isEmpty)
  }

  @Test("a single speech span becomes one window with pre-roll applied")
  func singleSpeechSpanGetsPreRoll() {
    let spans = [VADSpan(state: .speech, start: 5, end: 10)]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 4.7, end: 10)])
  }

  @Test("pre-roll clamps to 0 rather than going negative near the range start")
  func preRollClampsAtRangeStart() {
    let spans = [VADSpan(state: .speech, start: 0.1, end: 5)]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 0, end: 5)])
  }

  @Test("two speech spans separated by a short pause (< maxPauseSeconds) merge into one window")
  func shortPauseMerges() {
    // Gap between spans is 1.0s, under the 1.5s maxPauseSeconds.
    let spans = [
      VADSpan(state: .speech, start: 5, end: 10),
      VADSpan(state: .speech, start: 11, end: 15),
    ]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 4.7, end: 15)])
  }

  @Test("two speech spans separated by a long pause (>= maxPauseSeconds) split into two windows")
  func longPauseSplits() {
    // Gap between spans is 2.0s, over the 1.5s maxPauseSeconds.
    let spans = [
      VADSpan(state: .speech, start: 5, end: 10),
      VADSpan(state: .speech, start: 12, end: 15),
    ]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 4.7, end: 10), SegmentWindow(start: 11.7, end: 15)])
  }

  @Test(
    "a split window's pre-roll never eats back into the previous window's end, avoiding overlap"
  )
  func preRollClampsToPreviousWindowEnd() {
    // Gap is exactly maxPauseSeconds (1.5s), so this still splits (the merge
    // rule is strictly "<"), but the second window's naive pre-roll
    // (12.0 - 0.3 = 11.7) would land before the first window's end (10),
    // if the first span's own end were later. Construct that: first window
    // ends at 11 after its own end, second span starts at 11.2 -- pre-roll
    // would want 10.9, before the first window's end of 11.
    let spans = [
      VADSpan(state: .speech, start: 5, end: 11),
      VADSpan(state: .speech, start: 12.7, end: 15),
    ]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    // 12.7 - 0.3 isn't exactly representable in binary floating point, so
    // this compares with a tolerance rather than bitwise equality (unlike
    // the whole-number fixtures elsewhere in this suite).
    #expect(windows.count == 2)
    #expect(windows[0] == SegmentWindow(start: 4.7, end: 11))
    #expect(abs(windows[1].start - 12.4) < 0.0001)
    #expect(windows[1].end == 15)
  }

  @Test("a window's end clamps to rangeDuration, never extending past the requested range")
  func endClampsToRangeDuration() {
    let spans = [VADSpan(state: .speech, start: 25, end: 40)]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 24.7, end: 30)])
  }

  @Test("silence spans interleaved with speech spans are ignored for windowing")
  func silenceSpansIgnoredForWindowing() {
    let spans = [
      VADSpan(state: .silence, start: 0, end: 5),
      VADSpan(state: .speech, start: 5, end: 10),
      VADSpan(state: .silence, start: 10, end: 30),
    ]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 4.7, end: 10)])
  }

  @Test("out-of-order input spans are handled the same as sorted input")
  func outOfOrderSpansHandled() {
    let spans = [
      VADSpan(state: .speech, start: 12, end: 15),
      VADSpan(state: .speech, start: 5, end: 10),
    ]
    let windows = NaturalPauseSegmenter.segments(
      vadSpans: spans, rangeDuration: 30, options: options)
    #expect(windows == [SegmentWindow(start: 4.7, end: 10), SegmentWindow(start: 11.7, end: 15)])
  }
}
