import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation

/// `cleanup`'s actual pipeline, per `docs/product/specs/llm-stages.md`'s
/// "cleanup" section: read a `.transcript.md` (+ JSON sidecar if present),
/// run each segment through the LLM guardrail chain (skip high-confidence
/// utterances, build a minimal-change prompt, validate the candidate against
/// the original), and write `<...>.clean.md` atomically with `kind: clean`
/// and `derived_from` naming the source transcript.
///
/// Split the same way `transcribe`'s `TranscribePipeline`/`TranscribeRuntime`
/// are: this type takes already-resolved inputs (an injected `LLMBackend`,
/// already-read vocabulary terms, already-read prompt override) rather than
/// touching config/environment/the real LLM subprocess itself, so it's
/// directly unit-testable against fixture transcript files and a
/// `FakeLLMBackend` with no environment or real config file
/// (`docs/engineering-practices.md`'s tier-1 strategy). ``CleanupRuntime`` is
/// the thin glue that resolves those inputs from real config and calls in.
///
/// **Scope decision — no cross-segment chunking:** each ``TranscriptSegment``
/// (one speaker turn) is sent to the LLM independently; there is no
/// chunking-with-overlap of a single pathologically long segment's text.
/// Segments are already naturally short (VAD-bounded utterances), so this is
/// a defensible scope bound for now, not silently assumed — a future task
/// can add chunking if a real transcript ever needs it.
///
/// **Scope decision — no speaker name map:** `docs/product/specs/llm-stages.md`'s
/// optional "apply a speaker name map if present in the session" step is
/// diarization-dependent (Phase 5, not yet built — see
/// `docs/product/prompts/phase-4-multi-source-sessions.md`'s explicit "out
/// of scope: Diarization"), so it is not applied here.
enum CleanupPipeline {
  struct Dependencies: Sendable {
    var clock: any NowProviding
    var llmBackend: any LLMBackend
    var validator: CleanupValidator
    var skipPolicy: HighConfidenceSkipPolicy
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void

    static func production(llmBackend: any LLMBackend) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        llmBackend: llmBackend,
        validator: CleanupValidator(),
        skipPolicy: HighConfidenceSkipPolicy(),
        log: { message in
          FileHandle.standardError.write(Data(("cleanup: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
        }
      )
    }
  }

  struct Inputs: Sendable {
    /// Path to the source `.transcript.md` (or `.clean.md` — any rendered
    /// transcript document; cleanup doesn't care which stage produced it).
    var transcriptPath: String
    var out: String?
    /// The cleanup system prompt to use, or `nil` for
    /// `CleanupPromptBuilder`'s built-in default.
    var systemPrompt: String?
    /// Already-read, merged vocabulary terms (global + `--vocab`), or empty
    /// when vocab is disabled (`--no-vocab` / `[cleanup].use_vocab = false`).
    var vocabulary: [String]
  }

  static func run(inputs: Inputs, dependencies: Dependencies) async -> Int32 {
    let transcriptURL = URL(fileURLWithPath: inputs.transcriptPath)
    let markdown: String
    do {
      markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
    } catch {
      dependencies.writeStderr(
        "error: could not read transcript at \(inputs.transcriptPath): \(error)")
      return 1
    }

    let inputSidecarURL = sidecarURL(for: transcriptURL)
    let jsonSidecar = try? String(contentsOf: inputSidecarURL, encoding: .utf8)

    let document: TranscriptDocument
    do {
      document = try TranscriptParser.parse(markdown: markdown, jsonSidecar: jsonSidecar)
    } catch {
      dependencies.writeStderr(
        "error: could not parse transcript at \(inputs.transcriptPath): \(error)")
      return 1
    }

    let promptBuilder = CleanupPromptBuilder(
      systemPrompt: inputs.systemPrompt ?? CleanupPromptBuilder.defaultSystemPrompt,
      vocabulary: inputs.vocabulary
    )

    var skipped = 0
    var accepted = 0
    var fellBack = 0
    var cleanedSegments: [TranscriptSegment] = []
    cleanedSegments.reserveCapacity(document.segments.count)

    for turn in document.segments {
      if dependencies.skipPolicy.shouldSkip(turn.segment) {
        skipped += 1
        cleanedSegments.append(turn)
        continue
      }

      let prompt = promptBuilder.build(transcript: turn.segment.text)
      let candidateText: String
      do {
        candidateText = try await dependencies.llmBackend.complete(prompt).text
      } catch {
        dependencies.log(
          "LLM call failed for a segment, keeping the original text: \(error)")
        fellBack += 1
        cleanedSegments.append(turn)
        continue
      }

      switch dependencies.validator.validate(original: turn.segment.text, candidate: candidateText)
      {
      case .accept(let cleaned):
        accepted += 1
        var cleanedTurn = turn
        cleanedTurn.segment.text = cleaned
        cleanedSegments.append(cleanedTurn)
      case .fallback(let reason):
        fellBack += 1
        dependencies.log("rejected a cleanup candidate (\(reason)), keeping the original text")
        cleanedSegments.append(turn)
      }
    }

    let generated = dependencies.clock.now()
    // frontmatter.vocab records the *named lists* merged for a run (e.g.
    // "global", per TranscriptFrontmatter's doc comment) — not the raw terms
    // this pipeline injects into the LLM prompt (inputs.vocabulary). Cleanup
    // inherits whatever the source transcript already recorded there rather
    // than guessing a mapping from terms back to list names.
    var frontmatter = document.frontmatter
    frontmatter.kind = .clean
    frontmatter.derivedFrom = transcriptURL.lastPathComponent
    frontmatter.generated = generated

    let cleanedDocument = TranscriptDocument(frontmatter: frontmatter, segments: cleanedSegments)

    let outputURL =
      inputs.out.map { URL(fileURLWithPath: $0) } ?? cleanOutputURL(for: transcriptURL)
    let outputSidecarURL = sidecarURL(for: outputURL)

    do {
      let outputMarkdown = TranscriptRenderer.renderMarkdown(cleanedDocument)
      try AtomicFileIO.writeAtomically(to: outputURL) { tempURL in
        try outputMarkdown.write(to: tempURL, atomically: false, encoding: .utf8)
      }
      let outputJSON = TranscriptRenderer.renderJSON(cleanedDocument)
      try AtomicFileIO.writeAtomically(to: outputSidecarURL) { tempURL in
        try outputJSON.write(to: tempURL, atomically: false, encoding: .utf8)
      }
    } catch {
      dependencies.writeStderr("error: failed to write cleaned transcript: \(error)")
      return 1
    }

    dependencies.log(
      "run.summary: segments=\(document.segments.count) accepted=\(accepted) "
        + "fallback=\(fellBack) skipped=\(skipped) output=\(outputURL.path)"
    )
    return 0
  }

  /// `<...>.transcript.json` for `<...>.transcript.md` (same stem, `.md` →
  /// `.json`) — the sidecar naming convention `OutputPathResolution` also
  /// uses on the write side.
  private static func sidecarURL(for markdownURL: URL) -> URL {
    markdownURL.deletingPathExtension().appendingPathExtension("json")
  }

  /// `<...>.transcript.md` → `<...>.clean.md`; any other name gets `.clean.md`
  /// appended after stripping its extension, so `cleanup` still produces a
  /// sensible sibling file when pointed at a non-standard filename.
  private static func cleanOutputURL(for transcriptURL: URL) -> URL {
    let name = transcriptURL.lastPathComponent
    let directory = transcriptURL.deletingLastPathComponent()
    if name.hasSuffix(".transcript.md") {
      let stem = String(name.dropLast(".transcript.md".count))
      return directory.appendingPathComponent("\(stem).clean.md")
    }
    let stem = transcriptURL.deletingPathExtension().lastPathComponent
    return directory.appendingPathComponent("\(stem).clean.md")
  }
}
