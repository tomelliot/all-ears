import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation

/// `summarize`'s actual pipeline, per `docs/product/specs/llm-stages.md`'s
/// "summarize" section: read one or more transcripts (preferring a sibling
/// `.clean.md` over a `.transcript.md` when both exist), run each selected
/// preset's prompt over their combined text, and write `<...>.summary.md`
/// (single preset) or `<...>.<preset>.summary.md` (multiple), with
/// `kind: summary`, `preset`, and `derived_from`.
///
/// Split the same way `cleanup`'s `CleanupPipeline`/`CleanupRuntime` are:
/// this type takes already-resolved inputs (an injected `LLMBackend`,
/// already-loaded preset prompt contents) so it's directly unit-testable
/// against fixture transcript files and a `FakeLLMBackend`, with
/// ``SummarizeRuntime`` as the thin config/environment glue.
enum SummarizePipeline {
  /// A resolved `[[summarize.preset]]` entry: its name and its prompt file's
  /// already-read content (empty when `prompt_file` is unset/unreadable — a
  /// preset with no prompt still runs, just with no extra instructions
  /// beyond the transcript text itself, rather than failing the run).
  struct Preset: Sendable {
    var name: String
    var promptContent: String
  }

  struct Dependencies: Sendable {
    var clock: any NowProviding
    var llmBackend: any LLMBackend
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void

    static func production(llmBackend: any LLMBackend) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        llmBackend: llmBackend,
        log: { message in
          FileHandle.standardError.write(Data(("summarize: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
        }
      )
    }
  }

  struct Inputs: Sendable {
    var transcriptPaths: [String]
    var presets: [Preset]
    var out: String?
  }

  static func run(inputs: Inputs, dependencies: Dependencies) async -> Int32 {
    guard !inputs.transcriptPaths.isEmpty else {
      dependencies.writeStderr("error: at least one transcript path is required")
      return 1
    }
    guard !inputs.presets.isEmpty else {
      dependencies.writeStderr("error: at least one preset is required (--preset or --all-presets)")
      return 1
    }

    var documents: [TranscriptDocument] = []
    var resolvedNames: [String] = []
    for path in inputs.transcriptPaths {
      let resolvedURL = preferCleanedSibling(for: URL(fileURLWithPath: path))
      let markdown: String
      do {
        markdown = try String(contentsOf: resolvedURL, encoding: .utf8)
      } catch {
        dependencies.writeStderr(
          "error: could not read transcript at \(resolvedURL.path): \(error)")
        return 1
      }
      let sidecarURL = resolvedURL.deletingPathExtension().appendingPathExtension("json")
      let jsonSidecar = try? String(contentsOf: sidecarURL, encoding: .utf8)
      do {
        documents.append(try TranscriptParser.parse(markdown: markdown, jsonSidecar: jsonSidecar))
      } catch {
        dependencies.writeStderr(
          "error: could not parse transcript at \(resolvedURL.path): \(error)")
        return 1
      }
      resolvedNames.append(resolvedURL.lastPathComponent)
    }

    let combinedText = documents.map(bodyText).joined(separator: "\n\n")
    let baseFrontmatter = mergedFrontmatter(
      documents.map(\.frontmatter), now: dependencies.clock.now())
    let baseOutputURL = outputBaseURL(
      for: URL(fileURLWithPath: inputs.transcriptPaths[0]), explicitOut: inputs.out)

    for preset in inputs.presets {
      let prompt = LLMPrompt(stablePrefix: preset.promptContent, dynamicSuffix: combinedText)
      let summaryText: String
      do {
        summaryText = try await dependencies.llmBackend.complete(prompt).text
      } catch {
        dependencies.writeStderr(
          "error: LLM call failed for preset '\(preset.name)': \(error)")
        return 1
      }

      var frontmatter = baseFrontmatter
      frontmatter.preset = preset.name
      frontmatter.derivedFrom = resolvedNames.joined(separator: ", ")
      let document = TranscriptDocument(
        frontmatter: frontmatter,
        segments: [
          TranscriptSegment(
            source: baseFrontmatter.sources.first ?? "unknown", speaker: "Summary",
            segment: Segment(start: 0, end: 0, text: summaryText))
        ])

      let outputURL = outputURL(
        for: baseOutputURL, preset: preset.name, isOnlyPreset: inputs.presets.count == 1)
      let sidecarURL = outputURL.deletingPathExtension().appendingPathExtension("json")
      do {
        try AtomicFileIO.writeAtomically(to: outputURL) { tempURL in
          try TranscriptRenderer.renderMarkdown(document).write(
            to: tempURL, atomically: false, encoding: .utf8)
        }
        try AtomicFileIO.writeAtomically(to: sidecarURL) { tempURL in
          try TranscriptRenderer.renderJSON(document).write(
            to: tempURL, atomically: false, encoding: .utf8)
        }
      } catch {
        dependencies.writeStderr(
          "error: failed to write summary for preset '\(preset.name)': \(error)")
        return 1
      }
      dependencies.log("run.summary: preset=\(preset.name) output=\(outputURL.path)")
    }

    return 0
  }

  /// "cleaned preferred if both exist" (`docs/product/specs/llm-stages.md`):
  /// a `<...>.transcript.md` path is redirected to its sibling
  /// `<...>.clean.md` when that file exists; any other name (already
  /// `.clean.md`, or a non-standard name) is used as given.
  private static func preferCleanedSibling(for url: URL) -> URL {
    let name = url.lastPathComponent
    guard name.hasSuffix(".transcript.md") else { return url }
    let stem = String(name.dropLast(".transcript.md".count))
    let cleanURL = url.deletingLastPathComponent().appendingPathComponent("\(stem).clean.md")
    return FileManager.default.fileExists(atPath: cleanURL.path) ? cleanURL : url
  }

  private static func bodyText(_ document: TranscriptDocument) -> String {
    document.segments.map { "\($0.speaker): \($0.segment.text)" }.joined(separator: "\n")
  }

  /// Merges multiple input transcripts' frontmatter into one summary
  /// frontmatter: sources/vocab are unioned, the range spans the earliest
  /// start to the latest end, and speech/word totals are summed. `model`/
  /// `diarization` are echoed from the first document — summarize doesn't
  /// run its own ASR/diarization pass, so these describe what produced the
  /// underlying transcript(s), not this summary.
  private static func mergedFrontmatter(_ inputs: [TranscriptFrontmatter], now: Instant)
    -> TranscriptFrontmatter
  {
    let first = inputs[0]
    var sources: [SourceID] = []
    var seenSources = Set<SourceID>()
    var vocab: [String] = []
    var seenVocab = Set<String>()
    var start = first.range.start
    var end = first.range.end
    var speechSeconds = 0.0
    var wordCount = 0

    for frontmatter in inputs {
      for source in frontmatter.sources where seenSources.insert(source).inserted {
        sources.append(source)
      }
      for term in frontmatter.vocab where seenVocab.insert(term).inserted {
        vocab.append(term)
      }
      start = min(start, frontmatter.range.start)
      end = max(end, frontmatter.range.end)
      speechSeconds += frontmatter.speechSeconds
      wordCount += frontmatter.wordCount
    }

    return TranscriptFrontmatter(
      schema: first.schema,
      kind: .summary,
      session: first.session,
      sources: sources,
      range: TimeRange(start: start, end: end),
      model: first.model,
      diarization: first.diarization,
      generated: now,
      durationSeconds: end.interval(since: start),
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: vocab
    )
  }

  /// `<...>.transcript.md`/`<...>.clean.md` → `<...>.summary.md` (or the
  /// explicit `--out`, when given).
  private static func outputBaseURL(for firstTranscriptURL: URL, explicitOut: String?) -> URL {
    if let explicitOut { return URL(fileURLWithPath: explicitOut) }
    let name = firstTranscriptURL.lastPathComponent
    let directory = firstTranscriptURL.deletingLastPathComponent()
    for suffix in [".transcript.md", ".clean.md"] where name.hasSuffix(suffix) {
      let stem = String(name.dropLast(suffix.count))
      return directory.appendingPathComponent("\(stem).summary.md")
    }
    let stem = firstTranscriptURL.deletingPathExtension().lastPathComponent
    return directory.appendingPathComponent("\(stem).summary.md")
  }

  /// **Decision:** with exactly one preset, `baseOutputURL` (which already
  /// honors `--out` when given — see ``outputBaseURL(for:explicitOut:)``) is
  /// used as-is. With more than one preset there is no single unambiguous
  /// destination for one bare `--out` path to name, so each preset's output
  /// is `baseOutputURL` with `.<preset>` inserted before `.summary.md` —
  /// still built from `--out` when given, just disambiguated per preset
  /// rather than colliding on one path.
  private static func outputURL(
    for baseOutputURL: URL, preset: String, isOnlyPreset: Bool
  ) -> URL {
    if isOnlyPreset { return baseOutputURL }
    let name = baseOutputURL.lastPathComponent
    let directory = baseOutputURL.deletingLastPathComponent()
    guard name.hasSuffix(".summary.md") else {
      return directory.appendingPathComponent("\(name).\(preset).summary.md")
    }
    let stem = String(name.dropLast(".summary.md".count))
    return directory.appendingPathComponent("\(stem).\(preset).summary.md")
  }
}
