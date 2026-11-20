import EarsCore
import Testing

@testable import transcribe

@Suite("MicDuplicateSources")
struct MicDuplicateSourcesTests {
  /// 30 sentences of 6 words, one every 10 seconds, sharing no word with
  /// another speaker's.
  private func speech(_ speaker: String, offset: Double = 0) -> [Segment] {
    (0..<30).map { index in
      Segment(
        start: Double(index) * 10 + offset, end: Double(index) * 10 + offset + 4,
        text: (0..<6).map { "\(speaker)\(index)x\($0)" }.joined(separator: " "))
    }
  }

  private func source(_ id: String, _ segments: [Segment]) -> SourceTranscription {
    SourceTranscription(sourceID: SourceID(id), segments: segments)
  }

  @Test("a browser source that repeats the mic is detected; the real remote is kept")
  func copyOfMicIsDetected() {
    let detected = MicDuplicateSources.detect(in: [
      source("mic", speech("tom")),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", speech("tom", offset: 1)),
      source("browser:meet:t6", speech("tom", offset: 1)),
    ])
    #expect(detected == [SourceID("browser:meet:t5"), SourceID("browser:meet:t6")])
  }

  @Test("punctuation and case differences between two ASR passes do not hide a copy")
  func tokenizationIgnoresPunctuationAndCase() {
    let shouted = speech("tom").map {
      Segment(start: $0.start, end: $0.end, text: $0.text.uppercased() + "!")
    }
    let detected = MicDuplicateSources.detect(in: [
      source("mic", speech("tom")),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", shouted),
    ])
    #expect(detected == [SourceID("browser:meet:t5")])
  }

  @Test("a remote voice that bleeds into the mic is not a copy of it")
  func speakerBleedIsKept() {
    // The mic hears both people; the remote track carries only one of them.
    let detected = MicDuplicateSources.detect(in: [
      source("mic", speech("tom") + speech("jan", offset: 5)),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t3", speech("ana", offset: 7)),
    ])
    #expect(detected.isEmpty)
  }

  @Test("the same words at a different time are not a copy")
  func sameWordsElsewhereInTimeAreKept() {
    let detected = MicDuplicateSources.detect(in: [
      source("mic", speech("tom")),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", speech("tom", offset: 600)),
    ])
    #expect(detected.isEmpty)
  }

  @Test("the only speech-carrying browser source is never dropped")
  func lastRemoteSourceIsKept() {
    let detected = MicDuplicateSources.detect(in: [
      source("mic", speech("tom")),
      source("browser:meet:t5", speech("tom", offset: 1)),
      source("browser:meet:t3", []),
    ])
    #expect(detected.isEmpty)
  }

  @Test("too little mic speech is not enough evidence")
  func shortSampleIsKept() {
    let few = Array(speech("tom").prefix(5))
    let detected = MicDuplicateSources.detect(in: [
      source("mic", few),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", few),
    ])
    #expect(detected.isEmpty)
  }

  @Test("only browser sources are candidates, and no mic means nothing to compare")
  func nonBrowserSourcesAreIgnored() {
    #expect(
      MicDuplicateSources.detect(in: [
        source("mic", speech("tom")),
        source("browser:meet:t2", speech("jan", offset: 5)),
        source("app:us.zoom.xos", speech("tom")),
      ]).isEmpty)
    #expect(
      MicDuplicateSources.detect(in: [
        source("browser:meet:t2", speech("tom")),
        source("browser:meet:t5", speech("tom")),
      ]).isEmpty)
  }

  @Test("copies no richer than the mic are all dropped and the mic is kept")
  func equalCopiesAreDropped() {
    let resolution = MicDuplicateSources.resolve([
      source("mic", speech("tom")),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", speech("tom", offset: 1)),
    ])
    #expect(resolution.dropped == [SourceID("browser:meet:t5")])
    #expect(resolution.micReplacement == nil)
  }

  @Test("a copy that says clearly more than the mic replaces it over its span")
  func richerCopyReplacesMic() {
    // The mic kept every sentence's first four words; the copy has all six
    // plus a sentence the mic missed entirely.
    let clipped = speech("tom").map {
      Segment(
        start: $0.start, end: $0.end,
        text: $0.text.split(separator: " ").prefix(4).joined(separator: " "))
    }
    let full = speech("tom", offset: 1) + [Segment(start: 305, end: 309, text: "one more thing")]
    let resolution = MicDuplicateSources.resolve([
      source("mic", clipped),
      source("browser:meet:t2", speech("jan", offset: 5)),
      source("browser:meet:t5", full),
      source("browser:meet:t6", speech("tom", offset: 1)),
    ])
    #expect(resolution.micReplacement == SourceID("browser:meet:t5"))
    #expect(resolution.dropped == [SourceID("browser:meet:t6")])
    #expect(resolution.replacedSpan == 1...309)
  }

  @Test("no copies means nothing to resolve")
  func noCopiesResolveToNothing() {
    let resolution = MicDuplicateSources.resolve([
      source("mic", speech("tom")),
      source("browser:meet:t2", speech("jan", offset: 5)),
    ])
    #expect(resolution.isEmpty)
  }
}
