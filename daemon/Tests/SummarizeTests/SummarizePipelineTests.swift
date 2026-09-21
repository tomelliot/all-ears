import EarsCore
import EarsCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import summarize

@Suite("SummarizePipeline")
struct SummarizePipelineTests {
  private static func makeTempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SummarizePipelineTests-\(label)-\(UUID().uuidString)")
  }

  private static func writeFixtureTranscript(
    at directory: URL,
    name: String = "standup.transcript.md",
    sources: [SourceID] = ["mic"],
    text: String = "Morning standup. Let's keep this quick."
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      rangeRun: "2026-07-17T10-30-00Z_standup",
      sources: sources,
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: ["global"]
    )
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: sources[0], speaker: "You", segment: Segment(start: 0, end: 3, text: text))
      ])
    let url = directory.appendingPathComponent(name)
    try TranscriptRenderer.renderMarkdown(document).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  private static func dependencies(llmResults: [Result<LLMCompletionResult, Error>])
    -> (SummarizePipeline.Dependencies, FakeLLMBackend)
  {
    let backend = FakeLLMBackend(results: llmResults)
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { _ in }
    )
    return (deps, backend)
  }

  @Test("single transcript, single preset writes <...>.summary.md")
  func singlePresetWritesSummary() async throws {
    let directory = Self.makeTempDirectory("single")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Quick standup, no blockers."))
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Summarize briefly:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)
    #expect(recorded[0].stablePrefix == "Summarize briefly:")

    let outputURL = directory.appendingPathComponent("standup.summary.md")
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let content = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(content.contains("kind: summary"))
    #expect(content.contains("preset: brief"))
    #expect(content.contains("derived_from: standup.transcript.md"))
    #expect(content.contains("Quick standup, no blockers."))
  }

  @Test("multiple presets each get their own <...>.<preset>.summary.md")
  func multiplePresetsWriteSeparateFiles() async throws {
    let directory = Self.makeTempDirectory("multi-preset")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    let (deps, _) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Brief summary.")),
      .success(LLMCompletionResult(text: "- Action 1\n- Action 2")),
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(name: "brief", promptContent: "Brief:"),
          SummarizePipeline.Preset(name: "actions", promptContent: "Actions:"),
        ],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.brief.summary.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.actions.summary.md").path))
  }

  @Test("summarizes exactly the path it was given, with no sibling redirection")
  func usesTheGivenPathVerbatim() async throws {
    let directory = Self.makeTempDirectory("verbatim-path")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(
      at: directory, text: "raw unclean text")
    // A sibling `.clean.md` exists but is *not* what was asked for: the
    // caller (the daemon chain, or `--session`) names the input explicitly.
    _ = try Self.writeFixtureTranscript(
      at: directory, name: "standup.clean.md", text: "Cleaned, readable text.")

    let (deps, _) = Self.dependencies(llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let content = try String(
      contentsOf: directory.appendingPathComponent("standup.summary.md"), encoding: .utf8)
    #expect(content.contains("derived_from: standup.transcript.md"))
  }

  @Test("a preset's notes file is read as plain Markdown and labelled in the prompt")
  func notesAreLabelledInThePrompt() async throws {
    let directory = Self.makeTempDirectory("notes")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let notesURL = directory.appendingPathComponent("jotted.md")
    try "- ship the thing\n- ask Kevin".write(to: notesURL, atomically: true, encoding: .utf8)

    let (deps, backend) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "brief", promptContent: "Brief:",
            notes: PathTemplate("{output_root}/jotted.md"))
        ],
        out: nil, outputRoot: directory.path),
      dependencies: deps)

    #expect(exitCode == 0)
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(prompt.dynamicSuffix.contains("## Jotted notes\n\n- ship the thing\n- ask Kevin"))
    #expect(prompt.dynamicSuffix.contains("## Transcript\n\n"))
    #expect(prompt.dynamicSuffix.contains("Transcript body."))
  }

  @Test("a configured notes file that doesn't exist summarizes with empty notes")
  func missingNotesFallsBackToEmpty() async throws {
    let directory = Self.makeTempDirectory("missing-notes")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")

    let results = Mutex<[SummarizePipeline.PresetResult]>([])
    let stderr = Mutex<[String]>([])
    var (deps, backend) = Self.dependencies(
      llmResults: [
        .success(LLMCompletionResult(text: "Summary.")),
        .success(LLMCompletionResult(text: "Brief.")),
      ])
    deps.onPresetResult = { result in results.withLock { $0.append(result) } }
    deps.writeStderr = { line in stderr.withLock { $0.append(line) } }

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "notes", promptContent: "Notes:",
            notes: PathTemplate("{output_root}/absent.md")),
          SummarizePipeline.Preset(name: "brief", promptContent: "Brief:"),
        ],
        out: nil, outputRoot: directory.path),
      dependencies: deps)

    // Both presets succeed: the absent notes file is a warning, not a failure.
    #expect(exitCode == 0)
    let recorded = results.withLock { $0 }
    #expect(recorded.count == 2)
    #expect(recorded.filter(\.ok).count == 2)

    // The prompt still carries the labelled two-section shape, with the notes
    // half empty — that is what "an empty string for the notes" buys.
    let notesPrompt = try #require(await backend.receivedPrompts.first)
    #expect(notesPrompt.dynamicSuffix.hasPrefix("## Jotted notes\n\n\n\n## Transcript\n\n"))
    #expect(notesPrompt.dynamicSuffix.contains("Transcript body."))

    // The absence is reported, not swallowed.
    let warnings = stderr.withLock { $0 }
    #expect(warnings.contains { $0.contains("no notes file at") && $0.hasPrefix("warning:") })
  }

  @Test("out = {notes} overwrites the notes file, and frontmatter = false writes the body alone")
  func writesBackOverTheNotesFile() async throws {
    let directory = Self.makeTempDirectory("notes-writeback")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let notesURL = directory.appendingPathComponent("daily/2026-08-05.md")
    try FileManager.default.createDirectory(
      at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "- jotted".write(to: notesURL, atomically: true, encoding: .utf8)

    let (deps, backend) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "# Notes\n\n- jotted, expanded"))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "meeting-notes", promptContent: "Notes:",
            notes: PathTemplate("{output_root}/daily/2026-08-05.md"),
            out: PathTemplate("{notes}"),
            frontmatter: false)
        ],
        out: nil, outputRoot: directory.path),
      dependencies: deps)

    #expect(exitCode == 0)
    // The original notes were read before the write — the prompt saw them.
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(prompt.dynamicSuffix.contains("- jotted"))
    // ...and the note now holds the summary body, with no ears frontmatter
    // to collide with a vault's own, and no stray JSON sidecar beside it.
    let written = try String(contentsOf: notesURL, encoding: .utf8)
    #expect(written == "# Notes\n\n- jotted, expanded\n")
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("daily/2026-08-05.json").path))
  }

  @Test("two presets resolving to one path: the first keeps it, the second is renamed and logged")
  func collidingPresetsGetSeparatePaths() async throws {
    let directory = Self.makeTempDirectory("path-collision")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let notesURL = directory.appendingPathComponent("daily/2026-08-21.md")
    try FileManager.default.createDirectory(
      at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "- jotted".write(to: notesURL, atomically: true, encoding: .utf8)

    let logs = Mutex<[String]>([])
    let results = Mutex<[SummarizePipeline.PresetResult]>([])
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: FakeLLMBackend(results: [
        .success(LLMCompletionResult(text: "The meeting note.")),
        .success(LLMCompletionResult(text: "The workshop note.")),
      ]),
      log: { line in logs.withLock { $0.append(line) } },
      writeStderr: { _ in },
      onPresetResult: { result in results.withLock { $0.append(result) } })

    // Both presets are pointed at the same daily note — the config shape that
    // let a workshop-shaped summary overwrite a user-research note.
    let toTheDailyNote = PathTemplate("{output_root}/daily/2026-08-21.md")
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "meeting", promptContent: "Meeting:", out: toTheDailyNote, frontmatter: false),
          SummarizePipeline.Preset(
            name: "workshop", promptContent: "Workshop:", out: toTheDailyNote, frontmatter: false),
        ],
        out: nil, outputRoot: directory.path),
      dependencies: deps)

    #expect(exitCode == 0)
    // The first preset in run order keeps the resolved path, and nothing
    // overwrites what it just wrote.
    #expect(try String(contentsOf: notesURL, encoding: .utf8) == "The meeting note.\n")
    let renamedURL = directory.appendingPathComponent("daily/2026-08-21.workshop.md")
    #expect(try String(contentsOf: renamedURL, encoding: .utf8) == "The workshop note.\n")
    // Both notes are reported where they actually landed…
    #expect(
      results.withLock { $0 } == [
        SummarizePipeline.PresetResult(preset: "meeting", path: notesURL.path, ok: true),
        SummarizePipeline.PresetResult(preset: "workshop", path: renamedURL.path, ok: true),
      ])
    // …and the redirection names both presets and both paths.
    #expect(
      logs.withLock { $0 }.contains {
        $0.contains("preset 'workshop': \(notesURL.path) is already the output of preset 'meeting'")
          && $0.contains(renamedURL.path)
      })
  }

  @Test("--out overrides a preset's own out template, including out = {notes}")
  func explicitOutBeatsPresetOut() async throws {
    let directory = Self.makeTempDirectory("out-precedence")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let notesURL = directory.appendingPathComponent("daily/2026-08-05.md")
    try FileManager.default.createDirectory(
      at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "- jotted".write(to: notesURL, atomically: true, encoding: .utf8)
    let explicitURL = directory.appendingPathComponent("elsewhere/redirected.md")

    let (deps, _) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "meeting-notes", promptContent: "Notes:",
            notes: PathTemplate("{output_root}/daily/2026-08-05.md"),
            out: PathTemplate("{notes}"),
            frontmatter: false)
        ],
        out: explicitURL.path, outputRoot: directory.path),
      dependencies: deps)

    #expect(exitCode == 0)
    // The summary went where the flag said, parent directory created for it...
    #expect(try String(contentsOf: explicitURL, encoding: .utf8) == "Summary.\n")
    // ...and the notes file the preset would have overwritten is untouched.
    #expect(try String(contentsOf: notesURL, encoding: .utf8) == "- jotted")
  }

  @Test("the LLM sees the conversation's title, start, speakers and per-turn timestamps")
  func promptCarriesHeaderAndTimestamps() async throws {
    let directory = Self.makeTempDirectory("prompt-header")
    defer { try? FileManager.default.removeItem(at: directory) }

    let start = Instant(secondsSinceEpoch: 1_786_518_073)  // 2026-08-12T07:01:13Z
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .clean,
      rangeRun: "2026-08-12T07-01-13Z_meet",
      title: "meet 96DC3F7J7x0B",
      started: start,
      sources: ["mic", "browser:meet:webaudio-track-1"],
      range: TimeRange(start: start, end: start.advanced(by: 3347)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: start.advanced(by: 4000),
      durationSeconds: 3347,
      speechSeconds: 3000,
      wordCount: 20,
      vocab: []
    )
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "Tom Elliot",
          segment: Segment(start: 40, end: 41, text: "Nice to meet you.")),
        TranscriptSegment(
          source: "browser:meet:webaudio-track-1", speaker: "Alan Bradburne",
          segment: Segment(start: 94, end: 96, text: "Very good to meet you too.")),
      ])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcriptURL = directory.appendingPathComponent("meet.clean.md")
    try TranscriptRenderer.renderMarkdown(document).write(
      to: transcriptURL, atomically: true, encoding: .utf8)
    // With the sidecar, as the daemon chain always writes it: the Markdown
    // body alone carries no per-turn source, so this is what separates the
    // mic speaker from the remote one.
    try TranscriptRenderer.renderJSON(document).write(
      to: directory.appendingPathComponent("meet.clean.json"), atomically: true, encoding: .utf8)

    let (deps, backend) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "meeting", promptContent: "Notes:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let prompt = try #require(await backend.receivedPrompts.first)
    // The header dates the conversation the model is asked to write up...
    #expect(prompt.dynamicSuffix.contains("title: meet 96DC3F7J7x0B"))
    #expect(prompt.dynamicSuffix.contains("started: 2026-08-12T07:01:13Z"))
    // ...names the file it came from, so a prompt asked to link the transcript
    // quotes a path rather than inventing a plausible-looking one...
    #expect(prompt.dynamicSuffix.contains("transcript: \(transcriptURL.path)"))
    // ...and names who was in it, marking the mic speaker as the note's author
    // so identifying them is not left to guesswork over display names.
    #expect(
      prompt.dynamicSuffix.contains("speakers: Tom Elliot (me), Alan Bradburne"))
    // Every turn carries its wall-clock time, as the published transcript does.
    #expect(prompt.dynamicSuffix.contains("[07:01:53] Tom Elliot: Nice to meet you."))
    #expect(
      prompt.dynamicSuffix.contains("[07:02:47] Alan Bradburne: Very good to meet you too."))
  }

  @Test("the source transcript is linked back to the summary it produced")
  func stampsNoteLinkIntoTheSourceTranscript() async throws {
    let directory = Self.makeTempDirectory("backlink")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let before = try String(contentsOf: transcriptURL, encoding: .utf8)

    let (deps, _) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let after = try String(contentsOf: transcriptURL, encoding: .utf8)
    let summaryPath = directory.appendingPathComponent("standup.summary.md").path
    // Outside any vault the link falls back to the absolute path, which is
    // still a truthful pointer — see `VaultPath.linkTarget`.
    #expect(after.contains("note: \"[[\(summaryPath)]]\""))
    // Only the frontmatter moved: the body is byte-identical.
    #expect(
      after.components(separatedBy: "---\n").last == before.components(separatedBy: "---\n").last)
    // And it still parses.
    #expect(try TranscriptParser.parse(markdown: after, jsonSidecar: nil).frontmatter.note != nil)
  }

  @Test("a summary still succeeds when its source transcript can't be linked back")
  func unwritableSourceDoesNotFailThePreset() async throws {
    let directory = Self.makeTempDirectory("backlink-failure")
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory, text: "Transcript body.")
    let outURL = Self.makeTempDirectory("backlink-failure-out").appendingPathComponent("s.md")
    defer { try? FileManager.default.removeItem(at: outURL.deletingLastPathComponent()) }

    let warnings = Mutex<[String]>([])
    let backend = FakeLLMBackend(results: [.success(LLMCompletionResult(text: "Summary."))])
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { line in warnings.withLock { $0.append(line) } })

    // Read-only directory: the summary lands elsewhere, the in-place rewrite
    // of the transcript cannot.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: directory.path)

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: outURL.path),
      dependencies: deps)

    // The summary is the artifact that matters; a missing back-link is a
    // warning, not a lost summary.
    #expect(exitCode == 0)
    #expect(try String(contentsOf: outURL, encoding: .utf8).contains("Summary."))
    #expect(warnings.withLock { $0 }.contains { $0.contains("could not link") })
  }

  @Test("a Markdown transcript that isn't an ears document still summarizes, warning once")
  func summarizesAForeignTranscript() async throws {
    let directory = Self.makeTempDirectory("foreign-transcript")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A Granola-style export: no frontmatter, its own speaker/timestamp shape.
    let foreign = "**You**\n*00:07*\nSo that hardware in the loop…\n"
    let transcriptURL = directory.appendingPathComponent("Lucas - 12 June at 14-59.md")
    try foreign.write(to: transcriptURL, atomically: true, encoding: .utf8)

    let warnings = Mutex<[String]>([])
    let backend = FakeLLMBackend(results: [.success(LLMCompletionResult(text: "Summary."))])
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { line in warnings.withLock { $0.append(line) } })

    let outURL = directory.appendingPathComponent("note.md")
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(name: "meeting", promptContent: "Notes:", frontmatter: false)
        ],
        out: outURL.path),
      dependencies: deps)

    #expect(exitCode == 0)
    let prompt = try #require(await backend.receivedPrompts.first)
    // Its text reaches the model verbatim, under a header carrying the one
    // thing that *is* known about it...
    #expect(prompt.dynamicSuffix.contains(foreign))
    #expect(prompt.dynamicSuffix.contains("transcript: \(transcriptURL.path)"))
    // ...and nothing this pipeline would have had to invent.
    #expect(!prompt.dynamicSuffix.contains("started:"))
    #expect(!prompt.dynamicSuffix.contains("speakers:"))
    // The degraded input is reported rather than passed off as a clean parse.
    #expect(warnings.withLock { $0 }.contains { $0.contains("is not an ears transcript") })
    // It still gets linked to the note it produced, in a block created for it.
    let after = try String(contentsOf: transcriptURL, encoding: .utf8)
    #expect(after == "---\nnote: \"[[\(outURL.path)]]\"\n---\n\(foreign)")
    #expect(warnings.withLock { $0 }.contains { $0.contains("had no frontmatter") })
  }

  @Test("nobody is marked (me) when every speaker resolves to the mic")
  func rollCallStaysUnmarkedWhenSourcesDoNotSeparateSpeakers() async throws {
    let directory = Self.makeTempDirectory("roll-call-single-source")
    defer { try? FileManager.default.removeItem(at: directory) }
    // The stock fixture is one mic source with one speaker — the shape a
    // Markdown-only parse also degrades to, where every turn resolves to
    // `sources.first` whether or not it was really captured there.
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    let (deps, backend) = Self.dependencies(
      llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(prompt.dynamicSuffix.contains("speakers: You\n"))
    #expect(!prompt.dynamicSuffix.contains("(me)"))
  }

  @Test("merges sources/vocab and spans the range across multiple input transcripts")
  func mergesMultipleTranscripts() async throws {
    let directory = Self.makeTempDirectory("multi-input")
    defer { try? FileManager.default.removeItem(at: directory) }
    let micURL = try Self.writeFixtureTranscript(
      at: directory, name: "mic.transcript.md", sources: ["mic"], text: "Mic side.")
    let appURL = try Self.writeFixtureTranscript(
      at: directory, name: "app.transcript.md", sources: ["app:us.zoom.xos"], text: "App side.")

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Combined summary."))
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [micURL.path, appURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded[0].dynamicSuffix.contains("Mic side."))
    #expect(recorded[0].dynamicSuffix.contains("App side."))

    let content = try String(
      contentsOf: directory.appendingPathComponent("mic.summary.md"), encoding: .utf8)
    #expect(content.contains("sources:\n- mic\n- \"app:us.zoom.xos\""))
    // Quoted: the comma-joined value contains a "," (a YAML flow-significant
    // character), so FrontmatterRenderer's needsQuoting quotes it.
    #expect(content.contains("derived_from: \"mic.transcript.md, app.transcript.md\""))
  }

  @Test("--out overrides the single-preset output path")
  func explicitOutOverridesSinglePreset() async throws {
    let directory = Self.makeTempDirectory("explicit-out")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)
    let customOut = directory.appendingPathComponent("custom.md").path

    let (deps, _) = Self.dependencies(llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: customOut),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: customOut))
  }

  @Test("no presets is a clear, non-zero error")
  func noPresetsIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: ["/tmp/whatever.transcript.md"], presets: [], out: nil),
      dependencies: deps)
    #expect(exitCode == 64)
  }

  @Test(
    "a failing preset is reported per-preset — the rest still run, outputs[] carries ok:false, exit is non-zero"
  )
  func partialPresetFailureIsExpressible() async throws {
    let directory = Self.makeTempDirectory("partial-failure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    // Presets run in order; the middle one's LLM call fails hard (non-zero
    // exit — a stage failure, not a retryable timeout).
    let backend = FakeLLMBackend(results: [
      .success(LLMCompletionResult(text: "Brief summary.")),
      .failure(LLMBackendError.nonZeroExit(code: 1, stderr: "model crashed")),
      .success(LLMCompletionResult(text: "- Decision 1")),
    ])
    let collected = ResultCollector()
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { _ in },
      onPresetResult: { collected.record($0) }
    )

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(name: "brief", promptContent: "Brief:"),
          SummarizePipeline.Preset(name: "actions", promptContent: "Actions:"),
          SummarizePipeline.Preset(name: "decisions", promptContent: "Decisions:"),
        ],
        out: nil),
      dependencies: deps)

    // Exit 0 only when all presets succeeded: one hard LLM failure is a
    // stage failure (exit-code taxonomy, issue #61).
    #expect(exitCode == 4)

    // Every preset is reported, in run order — the failed one with ok:false
    // and no path, the others with their written summary's absolute path.
    let results = collected.results
    try #require(
      results.count == 3, "every preset must be reported, got \(results.count): \(results)")
    #expect(results.map(\.preset) == ["brief", "actions", "decisions"])
    #expect(results.map(\.ok) == [true, false, true])
    #expect(results[1].path == nil)
    for result in results where result.ok {
      let path = try #require(result.path)
      #expect(path.hasPrefix("/"), "a per-preset path must be absolute, got: \(path)")
      #expect(FileManager.default.fileExists(atPath: path))
    }

    // The surviving presets' files were still written: partial success is
    // real work kept, not discarded by the failure.
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.brief.summary.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.decisions.summary.md").path))

    // The error envelope built from these results expresses the partial
    // success ("2 of 3 presets"): outputs[] has ok:false for the failed
    // preset while the succeeded ones keep their paths.
    let envelope = SummarizeResultEnvelope.failure(
      exitClass: "stage-failed",
      message: "error: LLM call failed for preset 'actions'",
      results: results)
    #expect(!envelope.ok)
    #expect(envelope.outputs?.map(\.ok) == [true, false, true])
    #expect(envelope.outputs?[1].preset == "actions")
    #expect(envelope.output == nil)
  }

  /// Thread-safe per-preset result collector for `onPresetResult` (the hook
  /// is `@Sendable`, so a plain `var` capture won't do).
  private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SummarizePipeline.PresetResult] = []
    func record(_ result: SummarizePipeline.PresetResult) {
      lock.withLock { storage.append(result) }
    }
    var results: [SummarizePipeline.PresetResult] { lock.withLock { storage } }
  }

  @Test("a missing transcript file is a clear, non-zero error")
  func missingTranscriptIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: ["/nonexistent/path.transcript.md"],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")], out: nil),
      dependencies: deps)
    #expect(exitCode == 3)
  }
}

/// The 2026-08-12 Matthew Barras call, end to end through the real pipeline.
///
/// Everything that went wrong that day meets here: a session the platform
/// never named, jottings filed a directory below where the `notes` template
/// looks and under a short form of the attendee's name, and speaker
/// attribution that had to be repaired at session end. The note this produces
/// is the one the user should have got.
@Suite("SummarizePipeline — the misattributed one-to-one")
struct SummarizeMisattributedCallTests {
  private static let start = Instant(secondsSinceEpoch: 1_786_544_990)  // 2026-08-12T14:29:50Z
  private static let end = Instant(secondsSinceEpoch: 1_786_547_924)

  /// A published transcript carrying what reconciliation concluded: a title
  /// derived from the roster, the roster itself, and the caveats.
  private static func writeTranscript(at directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .clean,
      session: "ea510e3a-b9e8-4e9d-9844-0f5dbf7e5852",
      title: "Matthew Barras",
      started: start,
      attendees: ["Tom Elliot (me)", "Matthew Barras"],
      warnings: [
        "speaker attribution: dropped a binding of remote audio "
          + "(browser:meet:spaces-wUE9lE2sg5YB-devices-404) to you (Tom Elliot) — browser "
          + "capture only ever records other participants"
      ],
      sources: ["mic", "browser:meet:speaker-2"],
      range: TimeRange(start: start, end: end),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.6b"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: end,
      durationSeconds: 2934,
      speechSeconds: 1494.5,
      wordCount: 5019,
      vocab: [])
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Nice to meet you, Matt.")),
        TranscriptSegment(
          source: "browser:meet:speaker-2", speaker: "Matthew Barras",
          segment: Segment(start: 4, end: 8, text: "Based in York, in Yorkshire.")),
      ])
    let url = directory.appendingPathComponent("2026-08-12 - Matthew Barras.md")
    try TranscriptRenderer.renderMarkdown(document).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// The vault's real shape: the week folder holds a day folder the template
  /// does not know about, and the note is named "Matt Barras".
  private static func writeVault(at root: URL) throws -> URL {
    let day = root.appendingPathComponent("daily-notes/2026/08/33/2026-08-12")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let notes = day.appendingPathComponent("2026-08-12 - Matt Barras.md")
    try "barrasindustries.com\n\nhas codex + claude open 12 hours a day\n"
      .write(to: notes, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: start.advanced(by: 2200).secondsSinceEpoch)],
      ofItemAtPath: notes.path)
    return notes
  }

  @Test("the jottings are found, folded in, backed up, and the caveats reach the note")
  func foldsInTheNoteTheTemplateMissed() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SummarizeMisattributed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = try Self.writeTranscript(at: root.appendingPathComponent("Transcripts"))
    let notesURL = try Self.writeVault(at: root)
    let backups = root.appendingPathComponent("backups")

    let backend = FakeLLMBackend(results: [
      .success(LLMCompletionResult(text: "---\ntitle: Matthew Barras\n---\n\n## Matthew Barras"))
    ])
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Self.end), llmBackend: backend,
      log: { _ in }, writeStderr: { _ in })

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(
            name: "meeting", promptContent: "Fold in:",
            // The template as configured: no day folder, `{title}` in the name.
            notes: PathTemplate(
              "{output_root}/daily-notes/{year}/{month}/{week}/{date} - {title}.md"),
            out: PathTemplate("{notes}"),
            frontmatter: false)
        ],
        out: nil, outputRoot: root.path, backupDirectory: backups.path),
      dependencies: deps)

    #expect(exitCode == 0)

    // The jottings reached the prompt — the whole failure was that they didn't.
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(prompt.dynamicSuffix.contains("barrasindustries.com"))
    // ...along with the roster, so the model can name the other party even
    // when attribution is shaky, and the caveats, so it can hedge.
    #expect(prompt.dynamicSuffix.contains("attendees: Tom Elliot (me), Matthew Barras"))
    #expect(prompt.dynamicSuffix.contains("warning: speaker attribution: dropped a binding"))

    // The summary replaced the real note, not a phantom beside it.
    let written = try String(contentsOf: notesURL, encoding: .utf8)
    #expect(written.contains("## Matthew Barras"))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "daily-notes/2026/08/33/2026-08-12 - Matthew Barras.md"
        ).path))

    // The caveat is in the note, under the note's own frontmatter — which is
    // still the first thing in the file, or Obsidian would not read it.
    #expect(written.hasPrefix("---\ntitle: Matthew Barras\n---\n"))
    #expect(written.contains("> [!warning] All Ears"))
    #expect(written.contains("browser capture only ever records other participants"))

    // And the hand-typed original survives the overwrite.
    let backedUp = try String(
      contentsOf: backups.appendingPathComponent("2026-08-12 - Matt Barras.handnotes.md"),
      encoding: .utf8)
    #expect(backedUp.contains("barrasindustries.com"))
  }
}

/// The 2026-09-21 back-to-back calls. The Augustin Applegate call's summary
/// was published two minutes into the next call, a four-minute 1:1 with Matt
/// Silva that had no jottings. The locator took the fresh Augustin note as
/// "edited during the call", and the Matt summary overwrote it.
@Suite("SummarizePipeline — back-to-back calls")
struct SummarizeBackToBackCallTests {
  private static let start = Instant(secondsSinceEpoch: 1_790_004_723)  // 2026-09-21T15:32:03Z
  private static let end = Instant(secondsSinceEpoch: 1_790_004_981)  // 15:36:21Z
  /// When the Augustin summary landed: inside the Matt call.
  private static let augustinPublished = Instant(secondsSinceEpoch: 1_790_004_933)
  private static let mattSession = "9614295c-10ee-4db3-82af-dc16f5c79fe6"
  private static let augustinSession = "aa4a2068-523f-464a-aebe-f5f77e27470c"
  private static let dayFolder = "daily-notes/2026/09/39/2026-09-21"

  private static func writeTranscript(at directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .clean,
      session: mattSession,
      title: "Matt / Tom weekly 1:1",
      started: start,
      attendees: ["Matt Silva", "Tom Elliot (me)"],
      sources: ["mic", "browser:meet:t1"],
      range: TimeRange(start: start, end: end),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.6b"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: end,
      durationSeconds: 258,
      speechSeconds: 200,
      wordCount: 766,
      vocab: [])
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: "browser:meet:t1", speaker: "Matt Silva",
          segment: Segment(start: 0, end: 4, text: "Where are we on SOC 2?"))
      ])
    let url = directory.appendingPathComponent("2026-09-21 - Matt _ Tom weekly 1_1.md")
    try TranscriptRenderer.renderMarkdown(document).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// A note in the day folder, stamped with `modified`.
  private static func writeNote(
    _ root: URL, name: String, content: String, modified: Instant
  ) throws -> URL {
    let day = root.appendingPathComponent(dayFolder)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let url = day.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: modified.secondsSinceEpoch)],
      ofItemAtPath: url.path)
    return url
  }

  private static let augustinNote = """
    ---
    title: Augustin Applegate
    transcript: "[[Transcripts/2026/09/21/2026-09-21 - Augustin Applegate.md]]"
    ---

    ## Augustin Applegate — 2026-09-21
    """

  private static func mattSessionRecord() -> Session {
    Session(
      id: mattSession, title: "Matt / Tom weekly 1:1", state: .ended, started: start, ended: end,
      intervals: [SessionInterval(start: start, end: end)])
  }

  private static func run(
    _ root: URL, transcript: URL, sessions: [Session]
  ) async throws -> (Int32, FakeLLMBackend) {
    let backend = FakeLLMBackend(results: [
      .success(LLMCompletionResult(text: "## Weekly 1:1: SOC 2 & Handoff"))
    ])
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(end.advanced(by: 60)), llmBackend: backend,
      log: { _ in }, writeStderr: { _ in })
    let code = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcript.path],
        presets: [
          SummarizePipeline.Preset(
            name: "workshop", promptContent: "Fold in:",
            notes: PathTemplate(
              "{output_root}/daily-notes/{year}/{month}/{week}/{date} - {title}.md"),
            out: PathTemplate("{notes}"),
            frontmatter: false)
        ],
        out: nil, outputRoot: root.path, backupDirectory: root.appendingPathComponent("b").path,
        sessions: sessions),
      dependencies: deps)
    return (code, backend)
  }

  private static func makeRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("SummarizeBackToBack-\(label)-\(UUID().uuidString)")
  }

  @Test("another session's published note is neither read nor overwritten")
  func claimedNoteIsLeftAlone() async throws {
    let root = Self.makeRoot("claimed")
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try Self.writeTranscript(at: root.appendingPathComponent("Transcripts"))
    // No frontmatter link, so only the claim can exclude it.
    let note = try Self.writeNote(
      root, name: "2026-09-21 - Augustin Applegate.md", content: "## Augustin Applegate",
      modified: Self.augustinPublished)
    var augustin = Session(
      id: Self.augustinSession, title: "Augustin Applegate", state: .ended,
      started: Self.start.advanced(by: -1890))
    augustin.publishedNotes = [note.path]

    let (code, backend) = try await Self.run(
      root, transcript: transcript, sessions: [Self.mattSessionRecord(), augustin])

    #expect(code == 0)
    #expect(try String(contentsOf: note, encoding: .utf8) == "## Augustin Applegate")
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(!prompt.dynamicSuffix.contains("Augustin"))
  }

  @Test("a note linking another transcript is skipped even with no session records")
  func publishedNoteIsSkippedWithoutClaims() async throws {
    let root = Self.makeRoot("linked")
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try Self.writeTranscript(at: root.appendingPathComponent("Transcripts"))
    let note = try Self.writeNote(
      root, name: "2026-09-21 - Augustin Applegate.md", content: Self.augustinNote,
      modified: Self.augustinPublished)

    let (code, backend) = try await Self.run(root, transcript: transcript, sessions: [])

    #expect(code == 0)
    #expect(try String(contentsOf: note, encoding: .utf8) == Self.augustinNote)
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(!prompt.dynamicSuffix.contains("Augustin"))
  }

  @Test("a note matched on edit time alone is read but the summary goes to the template path")
  func weakMatchIsNotOverwritten() async throws {
    let root = Self.makeRoot("weak")
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try Self.writeTranscript(at: root.appendingPathComponent("Transcripts"))
    let scratch = try Self.writeNote(
      root, name: "2026-09-21 scratch.md", content: "soc2 auditor shortlist",
      modified: Self.start.advanced(by: 90))

    let (code, backend) = try await Self.run(
      root, transcript: transcript, sessions: [Self.mattSessionRecord()])

    #expect(code == 0)
    let prompt = try #require(await backend.receivedPrompts.first)
    #expect(prompt.dynamicSuffix.contains("soc2 auditor shortlist"))
    #expect(try String(contentsOf: scratch, encoding: .utf8) == "soc2 auditor shortlist")
    let templatePath = root.appendingPathComponent(
      "daily-notes/2026/09/39/2026-09-21 - Matt _ Tom weekly 1_1.md")
    #expect(
      try String(contentsOf: templatePath, encoding: .utf8)
        .contains("## Weekly 1:1: SOC 2 & Handoff"))
  }
}
