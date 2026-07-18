/// ``CleanupValidator``'s verdict on one LLM cleanup candidate: accept the
/// cleaned text, or fall back to the original because the candidate looks
/// hallucinated or over-edited.
public enum CleanupDecision: Sendable, Hashable {
  case accept(String)
  case fallback(reason: CleanupRejectionReason)
}

/// Why ``CleanupValidator`` rejected a candidate.
public enum CleanupRejectionReason: Sendable, Hashable, CustomStringConvertible {
  /// The candidate was empty (or all whitespace) after trimming.
  case candidateEmpty
  /// `candidate.count / original.count` fell outside the configured bounds --
  /// either truncation (the LLM dropped content) or padding (it added
  /// unrelated content), both length-detectable without inspecting words.
  case lengthRatioOutOfBounds(ratio: Double)
  /// Too large a fraction of the candidate's significant words don't appear
  /// anywhere in the original -- the length-independent hallucination/entity-
  /// drift signal (a candidate can pad without changing overall length by
  /// swapping in unrelated content of similar length).
  case novelContentExceeded(ratio: Double)

  public var description: String {
    switch self {
    case .candidateEmpty:
      return "candidate was empty"
    case .lengthRatioOutOfBounds(let ratio):
      return "length ratio \(ratio) out of bounds"
    case .novelContentExceeded(let ratio):
      return "novel word ratio \(ratio) exceeded bound"
    }
  }
}

/// The cleanup accept/fallback guardrail from `docs/product/specs/
/// llm-stages.md`'s "Refinement guardrails": "if the cleaned output diverges
/// from the source beyond a bound (length ratio, entity drift), reject it
/// and keep the original segment rather than shipping a hallucination."
///
/// Two independent, cheap-to-compute signals, either of which rejects on its
/// own:
///
/// 1. **Length ratio** -- `candidate.count / original.count` must fall
///    within `[minLengthRatio, maxLengthRatio]`. Catches both truncation
///    (the LLM dropped a clause) and gross padding.
/// 2. **Novel word ratio** -- the fraction of the candidate's significant
///    words (length >= 3, so short function words don't dominate the ratio)
///    that don't appear anywhere in the original. Catches padding/rewrites
///    that stay close in length but invent content (entity drift):
///    fabricated names, numbers, or clauses absent from the source.
///
/// The spec names these two signals but does not prescribe exact bounds;
/// the defaults below are this pass's conservative heuristic -- generous
/// enough to admit a genuine minimal edit (a homophone fix, punctuation,
/// light filler removal) but tight enough to catch the hallucinated-content
/// case the roadmap's Phase 3 exit criterion calls out. Both are exposed as
/// `var`s so `cleanup`'s config can retune them per `[cleanup]` settings
/// later without changing this type's shape.
public struct CleanupValidator: Sendable {
  public var minLengthRatio: Double
  public var maxLengthRatio: Double
  public var maxNovelWordRatio: Double

  public init(
    minLengthRatio: Double = 0.4,
    maxLengthRatio: Double = 1.8,
    maxNovelWordRatio: Double = 0.3
  ) {
    self.minLengthRatio = minLengthRatio
    self.maxLengthRatio = maxLengthRatio
    self.maxNovelWordRatio = maxNovelWordRatio
  }

  /// Decide whether `candidate` (the LLM's cleaned output for `original`) is
  /// safe to ship, or whether `cleanup` should fall back to `original`.
  public func validate(original: String, candidate: String) -> CleanupDecision {
    let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCandidate.isEmpty else {
      return .fallback(reason: .candidateEmpty)
    }

    let originalLength = Double(original.count)
    if originalLength > 0 {
      let ratio = Double(trimmedCandidate.count) / originalLength
      guard ratio >= minLengthRatio && ratio <= maxLengthRatio else {
        return .fallback(reason: .lengthRatioOutOfBounds(ratio: ratio))
      }
    }

    let originalWords = Set(Self.significantWords(in: original))
    let candidateWords = Self.significantWords(in: trimmedCandidate)
    if !candidateWords.isEmpty {
      let novelCount = candidateWords.filter { !originalWords.contains($0) }.count
      let novelRatio = Double(novelCount) / Double(candidateWords.count)
      guard novelRatio <= maxNovelWordRatio else {
        return .fallback(reason: .novelContentExceeded(ratio: novelRatio))
      }
    }

    return .accept(trimmedCandidate)
  }

  /// Lowercased alphanumeric words of length >= 3, in order (duplicates
  /// kept) -- short function words ("a", "is", "to") are excluded so they
  /// don't dilute the novel-word ratio in either direction.
  static func significantWords(in text: String) -> [String] {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 3 }
  }
}
