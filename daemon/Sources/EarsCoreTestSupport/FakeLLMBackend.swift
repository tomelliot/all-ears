import EarsCore

/// An in-memory ``LLMBackend`` for tests: returns a scripted completion (or
/// throws a scripted error) without spawning a process, and records every
/// prompt it was sent so a test can assert on them.
///
/// Matches the ``NullTranscriber``/``NullDiarizer`` fake-object convention --
/// a real conformance to the protocol kept out of the shipped backend
/// choices -- so `cleanup`'s guardrail logic (``CleanupValidator``,
/// ``HighConfidenceSkipPolicy``, ``CleanupPromptBuilder``) can be exercised
/// against a scriptable double instead of the real `llm` CLI subprocess. An
/// actor (not a struct) because it accumulates call history across
/// `complete(_:)` calls while staying `Sendable` across actor boundaries,
/// same reasoning as a real subprocess-backed conformer's internal state.
public actor FakeLLMBackend: LLMBackend {
  public nonisolated let info: LLMBackendInfo

  private var scriptedResults: [Result<LLMCompletionResult, Error>]
  public private(set) var receivedPrompts: [LLMPrompt] = []

  /// - Parameters:
  ///   - info: The backend metadata to expose.
  ///   - results: Scripted results returned in order, one per `complete(_:)`
  ///     call. When exhausted (including when empty), `complete(_:)` echoes
  ///     the prompt's `dynamicSuffix` back as a trivial passthrough
  ///     completion, which is enough for guardrail tests that don't care
  ///     what the "model" said.
  public init(
    info: LLMBackendInfo = LLMBackendInfo(name: "fake"),
    results: [Result<LLMCompletionResult, Error>] = []
  ) {
    self.info = info
    self.scriptedResults = results
  }

  public func complete(_ prompt: LLMPrompt) async throws -> LLMCompletionResult {
    receivedPrompts.append(prompt)
    guard !scriptedResults.isEmpty else {
      return LLMCompletionResult(text: prompt.dynamicSuffix)
    }
    let result = scriptedResults.removeFirst()
    switch result {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }
}
