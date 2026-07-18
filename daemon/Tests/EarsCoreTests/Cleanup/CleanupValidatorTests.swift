import Testing

@testable import EarsCore

@Suite("CleanupValidator")
struct CleanupValidatorTests {
  let validator = CleanupValidator()

  // This is the roadmap's stated Phase 3 exit criterion: "the validator
  // demonstrably rejects a hallucinated cleanup on a fixture." The candidate
  // here invents an entire clause -- a lost contract and layoffs -- with no
  // basis in the original segment, which is exactly the failure mode the
  // accept/fallback guardrail exists to catch (docs/product/specs/
  // llm-stages.md: "if the cleaned output diverges from the source beyond a
  // bound (length ratio, entity drift), reject it and keep the original").
  @Test("rejects a hallucinated cleanup and falls back to the original")
  func rejectsHallucination() {
    let original = "Nothing from me, the deploy went out last night."
    let hallucinated =
      "Nothing from me, the deploy went out last night, and we also lost the Northwind "
      + "contract and need to lay off the Boston team by Friday."

    let decision = validator.validate(original: original, candidate: hallucinated)

    guard case .fallback(let reason) = decision else {
      Issue.record("expected a fallback decision, got \(decision)")
      return
    }
    switch reason {
    case .lengthRatioOutOfBounds, .novelContentExceeded:
      break  // either signal catching this is correct
    case .candidateEmpty:
      Issue.record("expected a length/novelty rejection, not empty-candidate")
    }
  }

  @Test("accepts a minimal, faithful correction")
  func acceptsMinimalCorrection() {
    let original = "so um yeah i think kubctl needs a restart"
    let cleaned = "So, yeah, I think kubectl needs a restart."

    let decision = validator.validate(original: original, candidate: cleaned)

    guard case .accept(let text) = decision else {
      Issue.record("expected accept, got \(decision)")
      return
    }
    #expect(text == cleaned)
  }

  @Test("rejects an empty candidate")
  func rejectsEmptyCandidate() {
    let decision = validator.validate(original: "Some real content here.", candidate: "   ")
    #expect(decision == .fallback(reason: .candidateEmpty))
  }

  @Test("rejects a candidate drastically shorter than the original")
  func rejectsTruncation() {
    let original =
      "We discussed the roadmap for Q3, agreed on the API key rotation timeline, and Priya "
      + "will follow up with the vendor about pricing."
    let truncated = "We discussed the roadmap."

    let decision = validator.validate(original: original, candidate: truncated)

    guard case .fallback(let reason) = decision, case .lengthRatioOutOfBounds = reason else {
      Issue.record("expected a length-ratio rejection, got \(decision)")
      return
    }
  }

  @Test("rejects a candidate drastically longer than the original")
  func rejectsPadding() {
    let original = "Blocked on the API key rotation."
    let padded = String(
      repeating: "Blocked on the API key rotation and many other things. ", count: 5)

    let decision = validator.validate(original: original, candidate: padded)

    guard case .fallback(let reason) = decision, case .lengthRatioOutOfBounds = reason else {
      Issue.record("expected a length-ratio rejection, got \(decision)")
      return
    }
  }

  @Test("a homophone correction against the vocabulary is not flagged as novel content")
  func acceptsVocabCorrection() {
    let original = "The new hire's name is flour, spelled like the baking ingredient."
    let cleaned = "The new hire's name is Flora, spelled like the baking ingredient."

    let decision = validator.validate(original: original, candidate: cleaned)

    guard case .accept = decision else {
      Issue.record("expected accept, got \(decision)")
      return
    }
  }
}
