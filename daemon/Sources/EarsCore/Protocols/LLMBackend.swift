/// The base LLM backend seam: a text-completion service invoked prompt-in,
/// completion-out. Modeled on `docs/product/specs/llm-stages.md`'s shared
/// LLM backend: the default backend runs the **`llm` CLI** as a `command`
/// subprocess (prompt on stdin, completion on stdout); a future
/// `anthropic-sdk` backend can conform natively. `cleanup` and `summarize`
/// depend on this protocol, never on a concrete backend.
///
/// Mirrors the `Transcriber` family's "small base protocol, not a
/// god-object switch" shape (`docs/product/specs/model-interface.md`),
/// simplified because every LLM backend has exactly one shape -- text in,
/// text out -- so there is no capability variance to layer optional
/// protocols over yet.
///
/// "The backend is responsible only for prompt-in -> completion-out. Prompt
/// construction, chunking, and output writing belong to the tools" (same
/// spec) -- so `LLMPrompt`'s stable-prefix/dynamic-suffix split, the
/// minimal-change instructions, and vocabulary injection are all built by
/// the caller (see `CleanupPromptBuilder`), never by a conformer.
///
/// Failures are explicit, never a silent empty completion: a non-zero exit
/// or a timeout throws ``LLMBackendError``, which the caller's
/// ``CleanupValidator`` can then decide to fall back from.
///
/// `async` (unlike the compute-bound, synchronous ``Transcriber``/``VAD``)
/// because a real conformer awaits a subprocess exit -- genuine I/O, the
/// same reasoning that makes ``CaptureBackend``/``PermissionProviding``
/// `async`.
public protocol LLMBackend: Sendable {
  var info: LLMBackendInfo { get }

  /// Send `prompt` to the backend and await its completion.
  func complete(_ prompt: LLMPrompt) async throws -> LLMCompletionResult
}
