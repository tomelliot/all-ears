import Testing

@testable import EarsCore

/// Tier-0 coverage of ``StreamingDelta``, the append-only delta contract from
/// `docs/product/specs/transcribe.md`: monotonic cursor, trailing-incomplete-
/// unit hold-back (including the spec's named "trailing U+FFFD" and "partial
/// token completed by the next step" cases), and the end-of-stream flush rule.
@Suite("StreamingDelta")
struct StreamingDeltaTests {
  @Test("emits nothing for an empty hypothesis")
  func emptyHypothesis() {
    var delta = StreamingDelta()
    #expect(delta.advance("") == "")
    #expect(delta.emitted == "")
    #expect(delta.heldBack == "")
  }

  @Test("holds back a trailing partial token until the next step confirms it")
  func holdsBackTrailingPartialToken() {
    var delta = StreamingDelta()
    #expect(delta.advance("hello wor") == "hello ")
    #expect(delta.heldBack == "wor")

    // The next hypothesis completes the token and places a boundary after
    // it — only now is "world" safe to emit.
    #expect(delta.advance("hello world and") == "world ")
    #expect(delta.emitted == "hello world ")
    #expect(delta.heldBack == "and")
  }

  @Test("a hypothesis with no whitespace boundary emits nothing yet")
  func noBoundaryEmitsNothing() {
    var delta = StreamingDelta()
    #expect(delta.advance("hel") == "")
    #expect(delta.emitted == "")
    #expect(delta.heldBack == "hel")
  }

  @Test("holds back a trailing U+FFFD until a later hypothesis resolves it")
  func holdsBackTrailingReplacementCharacter() {
    var delta = StreamingDelta()
    // A partial multibyte decode surfaces as a trailing replacement
    // character; it must never reach a sink.
    #expect(delta.advance("caf\u{FFFD}") == "")
    #expect(delta.heldBack == "caf\u{FFFD}")

    // The next step re-decodes the tail with the full character available.
    #expect(delta.advance("café au lait") == "café au ")
    #expect(delta.emitted == "café au ")
    #expect(delta.heldBack == "lait")
  }

  @Test("the cursor never moves backward when the model revises emitted text")
  func monotonicCursor() {
    var delta = StreamingDelta()
    #expect(delta.advance("hello there ") == "hello there ")

    // A revision of already-emitted text emits nothing and retracts nothing.
    #expect(delta.advance("yellow there friend") == "")
    #expect(delta.emitted == "hello there ")

    // A hypothesis extending the emitted cursor resumes normal emission.
    #expect(delta.advance("hello there friend ") == "friend ")
    #expect(delta.emitted == "hello there friend ")
  }

  @Test("a divergent hypothesis leaves the held-back tail unchanged")
  func divergentHypothesisKeepsHeldBack() {
    var delta = StreamingDelta()
    #expect(delta.advance("hello wor") == "hello ")
    #expect(delta.advance("goodbye") == "")
    #expect(delta.heldBack == "wor")
    #expect(delta.finish() == "wor")
  }

  @Test("finish flushes a held-back partial word as a final commit")
  func finishFlushesHeldBackWord() {
    var delta = StreamingDelta()
    #expect(delta.advance("it works.") == "it ")
    #expect(delta.finish() == "works.")
    #expect(delta.emitted == "it works.")
    #expect(delta.heldBack == "")
  }

  @Test("finish discards a trailing U+FFFD rather than emitting a garbled tail")
  func finishDiscardsTrailingReplacementCharacter() {
    var delta = StreamingDelta()
    #expect(delta.advance("done no\u{FFFD}\u{FFFD}") == "done ")
    #expect(delta.finish() == "no")
    #expect(delta.emitted == "done no")
  }

  @Test("finish with nothing held back emits nothing")
  func finishEmpty() {
    var delta = StreamingDelta()
    #expect(delta.advance("all emitted ") == "all emitted ")
    #expect(delta.finish() == "")
    #expect(delta.emitted == "all emitted ")
  }

  @Test("finish with only a U+FFFD held back emits nothing")
  func finishOnlyReplacementCharacter() {
    var delta = StreamingDelta()
    #expect(delta.advance("\u{FFFD}") == "")
    #expect(delta.finish() == "")
    #expect(delta.emitted == "")
  }

  @Test("successive growing hypotheses produce an append-only reconstruction")
  func appendOnlyReconstruction() {
    var delta = StreamingDelta()
    let hypotheses = [
      "the",
      "the quick",
      "the quick brown",
      "the quick brown fox jumps",
      "the quick brown fox jumps over the lazy dog",
    ]
    var stream = ""
    for hypothesis in hypotheses {
      let emitted = delta.advance(hypothesis)
      // Append-only: what was already streamed is a strict prefix of the
      // stream after each step.
      stream += emitted
      #expect(stream == delta.emitted)
    }
    stream += delta.finish()
    #expect(stream == "the quick brown fox jumps over the lazy dog")
  }
}
