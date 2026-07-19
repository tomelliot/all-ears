import EarsCore
import EarsCoreTestSupport
import Foundation
import Testing

@testable import cleanup

/// Tier-1 fixture-driven tests, mirroring `TranscribePipelineTests`' pattern:
/// a real `.transcript.md` (+ JSON sidecar) is written to a temp directory
/// via the real renderers, `CleanupPipeline.run` is driven against it with a
/// `FakeLLMBackend`, and the real `.clean.md`/`.clean.json` output is read
/// back and asserted on. No environment or real config file involved.
@Suite("CleanupPipeline")
struct CleanupPipelineTests {
  private static func makeTempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "CleanupPipelineTests-\(label)-\(UUID().uuidString)")
  }

  private static func writeFixtureTranscript(
    at directory: URL,
    segments: [TranscriptSegment],
    writeSidecar: Bool = true
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: "2026-07-17T10-30-00Z_standup",
      sources: ["mic"],
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: []
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: segments)
    let markdownURL = directory.appendingPathComponent("standup.transcript.md")
    try TranscriptRenderer.renderMarkdown(document).write(
      to: markdownURL, atomically: true, encoding: .utf8)
    if writeSidecar {
      let jsonURL = directory.appendingPathComponent("standup.transcript.json")
      try TranscriptRenderer.renderJSON(document).write(
        to: jsonURL, atomically: true, encoding: .utf8)
    }
    return markdownURL
  }

  private static func dependencies(llmResults: [Result<LLMCompletionResult, Error>])
    -> (CleanupPipeline.Dependencies, FakeLLMBackend)
  {
    let backend = FakeLLMBackend(results: llmResults)
    let deps = CleanupPipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      validator: CleanupValidator(),
      skipPolicy: HighConfidenceSkipPolicy(),
      log: { _ in },
      writeStderr: { _ in }
    )
    return (deps, backend)
  }

  @Test("accepts a valid LLM correction and writes it to .clean.md")
  func acceptsValidCorrection() async throws {
    let directory = Self.makeTempDirectory("accept")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "hello there how are you"))
      ])

    // Punctuation/casing only -- no word changes -- so CleanupValidator's
    // novel-word-ratio check has nothing to flag.
    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Hello there, how are you?"))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)

    let cleanedMarkdown = try String(
      contentsOf: directory.appendingPathComponent("standup.clean.md"), encoding: .utf8)
    #expect(cleanedMarkdown.contains("kind: clean"))
    // Not quoted: "standup.transcript.md" needs no YAML quoting (no leading
    // digit/special character), per FrontmatterRenderer's `needsQuoting`.
    #expect(cleanedMarkdown.contains("derived_from: standup.transcript.md"))
    #expect(cleanedMarkdown.contains("Hello there, how are you?"))
  }

  @Test("falls back to the original text when the LLM candidate fails validation")
  func fallsBackOnInvalidCandidate() async throws {
    let directory = Self.makeTempDirectory("fallback")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Hello there."))
      ])

    // Wildly different length + invented content -> CleanupValidator rejects it.
    let (deps, _) = Self.dependencies(llmResults: [
      .success(
        LLMCompletionResult(
          text:
            "This is a completely different sentence about something the original never mentioned at all."
        ))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let cleanedMarkdown = try String(
      contentsOf: directory.appendingPathComponent("standup.clean.md"), encoding: .utf8)
    #expect(cleanedMarkdown.contains("Hello there."))
  }

  @Test(
    """
    confidence-based skipping never fires against a persisted transcript, \
    since neither the Markdown body nor the JSON sidecar records confidence \
    (TranscriptParser's documented lossy field) -- this locks in that known \
    limitation rather than assuming it works.
    """)
  func confidenceBasedSkipNeverFiresOnARereadTranscript() async throws {
    let directory = Self.makeTempDirectory("skip")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Already clean.", confidence: 0.99))
      ])

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Already clean."))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)
  }

  @Test("keeps the original text when the LLM call itself throws")
  func keepsOriginalOnLLMFailure() async throws {
    let directory = Self.makeTempDirectory("llm-error")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Original text."))
      ])

    let (deps, _) = Self.dependencies(llmResults: [.failure(LLMBackendError.timedOut)])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let cleanedMarkdown = try String(
      contentsOf: directory.appendingPathComponent("standup.clean.md"), encoding: .utf8)
    #expect(cleanedMarkdown.contains("Original text."))
  }

  @Test("--out overrides the output path")
  func explicitOutOverridesPath() async throws {
    let directory = Self.makeTempDirectory("explicit-out")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ])
    let customOut = directory.appendingPathComponent("custom.clean.md").path

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: customOut, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: customOut))
    // Sidecar is derived from the output path itself (custom.clean.md ->
    // custom.clean.json), not from the input transcript's name.
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("custom.clean.json").path))
  }

  @Test("works with no JSON sidecar present (Markdown-only fallback)")
  func worksWithoutSidecar() async throws {
    let directory = Self.makeTempDirectory("no-sidecar")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ],
      writeSidecar: false)

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil, systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.clean.md").path))
  }

  @Test("a missing transcript file is a clear, non-zero error")
  func missingTranscriptIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: "/nonexistent/path.transcript.md", out: nil, systemPrompt: nil,
        vocabulary: []),
      dependencies: deps)
    #expect(exitCode == 1)
  }
}
