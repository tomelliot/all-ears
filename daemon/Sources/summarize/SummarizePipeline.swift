import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation

/// `summarize`'s actual pipeline, per `docs/specs/llm-stages.md`'s
/// "summarize" section: read one or more transcripts at the paths given
/// (the caller names them — `summarize --session` resolves the session's
/// cleaned transcript, and the daemon chain passes cleanup's output
/// forward), optionally read each preset's companion notes file, run every
/// selected preset's prompt over the result, and write `<...>.summary.md`
/// (single preset) or `<...>.<preset>.summary.md` (multiple), with
/// `kind: summary`, `preset`, and `derived_from`.
///
/// A preset can override all of that: `out` names its own destination
/// through a ``PathTemplate`` (including `{notes}`, to write back over its
/// own notes file), and `frontmatter = false` emits the body alone for a
/// destination — an Obsidian vault, say — that owns its own frontmatter.
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
    /// `notes`: a path template for a companion notes file, read as **plain
    /// Markdown** — no frontmatter parsing, no sidecar. When set and the
    /// expanded path doesn't exist, the preset still runs with an empty
    /// notes section and warns on stderr, so a call with no jottings waiting
    /// still gets summarized from its transcript.
    var notes: PathTemplate? = nil
    /// `out`: a path template for this preset's output, overriding the
    /// default sibling naming. May reference `{notes}` to write back over
    /// the notes file — safe because every input is read before any write.
    var out: PathTemplate? = nil
    /// `frontmatter`: `false` emits the summary body alone, with no YAML
    /// block and no JSON sidecar — the artifact is then plain Markdown, not
    /// an ears document, which is what writing into a vault (whose own
    /// frontmatter the `kind:`/`preset:` stamp would collide with) needs.
    var frontmatter: Bool = true
  }

  /// One preset's outcome, reported through
  /// ``Dependencies/onPresetResult`` as the run progresses — the per-preset
  /// result surface `--json`'s envelope carries (issue #63), so partial
  /// success ("2 of 3 presets") is expressible instead of collapsing into a
  /// single exit code. `path` is the written summary's absolute path on
  /// success, absent on failure. Doubles as the envelope's wire type
  /// (`{preset, path, ok}` per `shared/stage-envelopes/summarize.v1.schema.json`).
  struct PresetResult: Codable, Sendable, Equatable {
    var preset: String
    var path: String? = nil
    var ok: Bool
  }

  struct Dependencies: Sendable {
    var clock: any NowProviding
    var llmBackend: any LLMBackend
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void
    /// Called once per selected preset, in run order, with that preset's
    /// outcome. Default no-op: plain-mode callers don't consume it.
    var onPresetResult: @Sendable (PresetResult) -> Void = { _ in }

    static func production(
      llmBackend: any LLMBackend,
      onError: (@Sendable (String) -> Void)? = nil
    ) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        llmBackend: llmBackend,
        log: { message in
          FileHandle.standardError.write(Data(("summarize: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        }
      )
    }
  }

  struct Inputs: Sendable {
    var transcriptPaths: [String]
    var presets: [Preset]
    var out: String?
    /// `--notes <path>`: an ad-hoc companion notes file, overriding the
    /// selected preset's own `notes` template. Single-preset runs only —
    /// the runtime rejects it otherwise.
    var notes: String? = nil
    /// The configured `output_root`, already `~`-expanded.
    var outputRoot: String = ""
    var weekNumbering: WeekNumbering = .us
    /// Where a note about to be overwritten is copied first. Empty disables
    /// backups.
    ///
    /// Defaulted **off**, and set explicitly by ``SummarizeRuntime`` — the one
    /// production caller. A default of the real path meant every unit test
    /// that constructs `Inputs` wrote its fixture notes into the user's home
    /// directory, which is a thing a test suite must never do; opting in at
    /// the single site that has a real user to protect is the safer default
    /// in the direction that matters.
    var backupDirectory: String = ""
    /// The daemon's session records. The locator reads the call's intervals
    /// from this run's own session, and every other session's published
    /// notes as notes it must not match. Empty (a store-less manual run)
    /// falls back to the transcript's range and no claims.
    var sessions: [Session] = []
  }

  static func run(inputs: Inputs, dependencies: Dependencies) async -> Int32 {
    // Defensive twins of the runtime's own guards: usage-shaped absences.
    guard !inputs.transcriptPaths.isEmpty else {
      dependencies.writeStderr("error: at least one transcript path is required")
      return ExitClass.usage.code
    }
    guard !inputs.presets.isEmpty else {
      dependencies.writeStderr("error: at least one preset is required (--preset or --all-presets)")
      return ExitClass.usage.code
    }

    var transcripts: [TranscriptInput] = []
    var resolvedNames: [String] = []
    for path in inputs.transcriptPaths {
      let resolvedURL = URL(fileURLWithPath: path)
      let markdown: String
      do {
        markdown = try String(contentsOf: resolvedURL, encoding: .utf8)
      } catch {
        dependencies.writeStderr(
          "error: could not read transcript at \(resolvedURL.path): \(error)")
        return ExitClass.inputMissing.code
      }
      let sidecarURL = resolvedURL.deletingPathExtension().appendingPathExtension("json")
      let jsonSidecar = try? String(contentsOf: sidecarURL, encoding: .utf8)
      // A transcript that isn't an *ears* transcript still summarizes. The
      // stage's job is "summarize the transcript at this path", and a vault
      // holds plenty of Markdown transcripts this pipeline never produced —
      // exports from other tools, hand-written notes of a call. Refusing them
      // bought nothing: the prompt reads prose either way, and the parse only
      // exists to recover metadata that a foreign transcript simply lacks.
      // What it costs is the header: no title, start or speaker roll-call,
      // so the prompt sees the file's own speaker labels and nothing more.
      let document = try? TranscriptParser.parse(markdown: markdown, jsonSidecar: jsonSidecar)
      if document == nil {
        dependencies.writeStderr(
          "warning: \(resolvedURL.path) is not an ears transcript; summarizing its text with "
            + "no title, start time or speaker roll-call")
      }
      transcripts.append(
        TranscriptInput(path: path, document: document, rawText: markdown))
      resolvedNames.append(resolvedURL.lastPathComponent)
    }

    let now = dependencies.clock.now()
    let combinedText = transcripts.map(bodyText).joined(separator: "\n\n")
    let baseFrontmatter = mergedFrontmatter(
      transcripts.map { $0.document?.frontmatter ?? unknownFrontmatter(now: now) }, now: now)
    let baseOutputURL = outputBaseURL(
      for: URL(fileURLWithPath: inputs.transcriptPaths[0]), explicitOut: inputs.out)

    // Every preset's destination and companion notes are resolved, and every
    // notes file read, **before any write happens**. That ordering is what
    // makes an `out = "{notes}"` preset safe: the file it overwrites has
    // already been read, by this preset and by any other.
    let context = templateContext(inputs, baseFrontmatter)
    let plans = inputs.presets.map { preset -> PresetPlan in
      // `--notes` is an explicit instruction and is used verbatim; only a
      // template-derived path is searched for, because only a template can be
      // wrong about where the user actually filed the note.
      var locatorReason: String? = nil
      var writeBackPath: String? = nil
      let notesPath: String?
      if let explicit = inputs.notes {
        notesPath = explicit
      } else if let template = preset.notes {
        let located = NotesLocator.locate(
          locatorContext(
            template.expand(context), baseFrontmatter, transcriptPaths: inputs.transcriptPaths,
            sessions: inputs.sessions))
        switch located {
        case .exact(let path):
          notesPath = path
        case .matched(let path, let reason, let confident):
          notesPath = path
          locatorReason = reason
          // A match on edit time alone supplies the notes but is not written
          // over: `{notes}` stays the template's path, so a wrong match adds
          // a file instead of replacing someone else's note.
          if !confident {
            writeBackPath = template.expand(context)
            locatorReason = reason + "; no participant named, so it is read but not overwritten"
          }
        case .notFound:
          // The template's path, still — it is what the miss is reported
          // against, and what `out = "{notes}"` would have written to.
          notesPath = template.expand(context)
        }
      } else {
        notesPath = nil
      }
      var notesContext = context
      notesContext.notes = writeBackPath ?? notesPath
      let notesContent = notesPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
      return PresetPlan(
        preset: preset,
        notesPath: notesPath,
        locatorReason: locatorReason,
        // A configured path that doesn't resolve degrades to `""` rather than
        // `nil`: the prompt keeps the two-section shape it was written for,
        // and `nil` stays reserved for "this preset configures no notes".
        notes: notesPath == nil ? nil : (notesContent ?? ""),
        notesMissing: notesPath != nil && notesContent == nil,
        // `--out` outranks a preset's `out` template, matching how `--notes`
        // already outranks `notes` just above and how `--set` outranks config
        // everywhere else: the flag is the highest-precedence layer, not the
        // lowest. With no template in play the destination falls through to
        // `baseOutputURL`, which `outputBaseURL(for:explicitOut:)` has already
        // resolved to the explicit path. A preset whose `out` is `{notes}` is
        // redirected too — overriding the destination is the whole point of
        // the flag.
        outputURL: (inputs.out == nil
          ? preset.out.map { URL(fileURLWithPath: $0.expand(notesContext)) } : nil)
          ?? outputURL(
            for: baseOutputURL, preset: preset.name,
            isOnlyPreset: inputs.presets.count == 1))
    }
    let resolved = disambiguated(plans, dependencies: dependencies)

    // Presets run independently (issue #63): one preset's failure no longer
    // aborts the rest — each outcome is reported through `onPresetResult`, so
    // partial success ("2 of 3 presets") is expressible in the `--json`
    // envelope instead of collapsing into the first failure. The run still
    // exits non-zero unless *all* presets succeeded, carrying the first
    // failure's taxonomy class (issue #61).
    var firstFailure: ExitClass? = nil
    for plan in resolved {
      let preset = plan.preset
      // A configured notes file that isn't there used to fail this preset, on
      // the reasoning that a fold-in prompt would silently lose the jottings.
      // In practice the common case is the opposite one: most captured calls
      // have no note waiting at the templated path, and failing there left
      // every such session with a transcript and no summary at all. The
      // preset now runs against an empty notes section — the prompt still
      // sees `## Jotted notes` / `## Transcript` and simply has nothing to
      // fold — and the absence is reported rather than swallowed.
      if plan.notesMissing, let notesPath = plan.notesPath {
        dependencies.writeStderr(
          "warning: preset '\(preset.name)': no notes file at \(notesPath); "
            + "summarizing from the transcript alone")
      }
      if let reason = plan.locatorReason, let notesPath = plan.notesPath {
        dependencies.log(
          "preset '\(preset.name)': notes matched at \(notesPath) (\(reason)) rather than the "
            + "path the template constructs")
      }

      let prompt = LLMPrompt(
        stablePrefix: preset.promptContent,
        dynamicSuffix: promptBody(notes: plan.notes, transcript: combinedText))
      let summaryText: String
      do {
        summaryText = try await dependencies.llmBackend.complete(prompt).text
      } catch {
        // Classified at the site that knows the cause (issue #61): a timeout
        // is a retryable upstream outage (5); a crashed or missing model
        // command is a hard stage failure (4). Either way the remaining
        // presets still run — presets are few, and keeping a mostly
        // -successful run's other summaries beats discarding them.
        dependencies.writeStderr(
          "error: LLM call failed for preset '\(preset.name)': \(error)")
        dependencies.onPresetResult(PresetResult(preset: preset.name, ok: false))
        if firstFailure == nil { firstFailure = ExitClass.classifying(llmError: error) }
        continue
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

      let outputURL = plan.outputURL
      do {
        // `frontmatter = false` means this artifact is plain Markdown, not an
        // ears document — so it gets no YAML block, and no JSON sidecar
        // either: a stray `.json` beside a vault note is pollution, and there
        // is no ears document for it to describe.
        // Nothing that was typed by hand is destroyed without a copy
        // surviving. This runs for any destination that already exists, not
        // just `out = "{notes}"`, because "the file I am about to replace
        // might be irreplaceable" is true of every one of them. A backup that
        // *fails* stops the write: losing the summary is recoverable (rerun
        // it), losing the note is not.
        if !inputs.backupDirectory.isEmpty,
          let backup = try NoteBackup.preserve(
            outputURL.path, directory: inputs.backupDirectory)
        {
          dependencies.log("preset '\(preset.name)': backed up \(outputURL.path) to \(backup)")
        }
        let body = summaryText.hasSuffix("\n") ? summaryText : summaryText + "\n"
        let annotated = annotate(body, warnings: noteWarnings(plan, baseFrontmatter))
        let markdown = preset.frontmatter ? TranscriptRenderer.renderMarkdown(document) : annotated
        try AtomicFileIO.writeAtomically(to: outputURL) { tempURL in
          try markdown.write(to: tempURL, atomically: false, encoding: .utf8)
        }
        if preset.frontmatter {
          let sidecarURL = outputURL.deletingPathExtension().appendingPathExtension("json")
          try AtomicFileIO.writeAtomically(to: sidecarURL) { tempURL in
            try TranscriptRenderer.renderJSON(document).write(
              to: tempURL, atomically: false, encoding: .utf8)
          }
        }
      } catch {
        dependencies.writeStderr(
          "error: failed to write summary for preset '\(preset.name)': \(error)")
        dependencies.onPresetResult(PresetResult(preset: preset.name, ok: false))
        if firstFailure == nil { firstFailure = .stageFailed }
        continue
      }
      // The inverse link, now that this preset's destination is known and on
      // disk: each input transcript gets a `note:` pointing at it, so the
      // pair is navigable from either end. Best-effort — a summary that was
      // written is a successful preset whether or not its source could be
      // annotated, so a failure here warns and leaves the result alone.
      stampNoteLink(
        into: inputs.transcriptPaths, target: outputURL.path, preset: preset.name,
        dependencies: dependencies)
      dependencies.log("run.summary: preset=\(preset.name) output=\(outputURL.path)")
      // Standardized so the reported path is always absolute with no `.`/`..`
      // components — consumers (the daemon, `--json` scripting) read it from
      // a different cwd, matching the plain result line's own convention.
      dependencies.onPresetResult(
        PresetResult(
          preset: preset.name,
          path: URL(fileURLWithPath: outputURL.path).standardizedFileURL.path,
          ok: true))
    }

    return (firstFailure ?? .success).code
  }

  /// Writes `note: "[[…]]"` into each input transcript's frontmatter, naming
  /// the summary just published from it.
  ///
  /// This is the one place `summarize` writes to its own input, and it happens
  /// only after that input has been fully read and the summary is on disk —
  /// the "every input is read before any write" ordering the `out = "{notes}"`
  /// case depends on still holds. The edit is a text splice into the YAML
  /// block (``TranscriptFrontmatterEditor``), not a parse/render round trip,
  /// so a transcript's turns are never rewritten to add a link.
  ///
  /// Failure is not this preset's failure: the summary exists and is
  /// correct, and losing it over an unwritable source file would be a worse
  /// outcome than a missing back-link. The absence is warned about instead.
  private static func stampNoteLink(
    into transcriptPaths: [String], target: String, preset: String, dependencies: Dependencies
  ) {
    let link = "[[\(VaultPath.linkTarget(target))]]"
    for path in transcriptPaths {
      do {
        let markdown = try String(contentsOfFile: path, encoding: .utf8)
        let updated = TranscriptFrontmatterEditor.settingNote(link, in: markdown)
        guard updated != markdown else { continue }
        if !TranscriptFrontmatterEditor.hasFrontmatterBlock(markdown) {
          dependencies.writeStderr(
            "warning: preset '\(preset)': \(path) had no frontmatter; added one holding "
              + "just its note: link")
        }
        try AtomicFileIO.writeAtomically(to: URL(fileURLWithPath: path)) { tempURL in
          try updated.write(to: tempURL, atomically: false, encoding: .utf8)
        }
      } catch {
        dependencies.writeStderr(
          "warning: preset '\(preset)': could not link \(path) back to its note: \(error)")
      }
    }
  }

  /// One input transcript: its path, its parse if it is an ears document, and
  /// its raw text either way.
  ///
  /// ``document`` is `nil` for a Markdown transcript this pipeline did not
  /// produce — a vault full of exports from other tools is the common case,
  /// and those summarize perfectly well from their text alone.
  private struct TranscriptInput: Sendable {
    var path: String
    var document: TranscriptDocument?
    var rawText: String
  }

  /// Stand-in frontmatter for an input with none, used only to give a
  /// `frontmatter = true` preset's summary a document to be derived from.
  ///
  /// Every field records ignorance rather than a plausible value: the model
  /// that produced a foreign transcript is genuinely unknown, and a summary
  /// claiming it came from this pipeline's ASR would be a lie told in
  /// metadata, where it is hardest to notice. A zero range and empty sources
  /// say the same thing about timing and capture.
  private static func unknownFrontmatter(now: Instant) -> TranscriptFrontmatter {
    TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      sources: [],
      range: TimeRange(start: now, end: now),
      model: TranscriptModelInfo(name: "unknown", backend: "unknown", version: "unknown"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: now,
      durationSeconds: 0,
      speechSeconds: 0,
      wordCount: 0,
      vocab: [])
  }

  /// One preset's fully-resolved destination and companion notes, computed
  /// for every preset before any write happens.
  private struct PresetPlan: Sendable {
    var preset: Preset
    /// The resolved `notes` path, when this preset configures one — the
    /// template's own path when that file exists, otherwise whatever
    /// ``NotesLocator`` matched (or, on a miss, the template's path again, so
    /// the failure is reported against the place that was looked).
    var notesPath: String?
    /// Why ``notesPath`` differs from what the template constructed, when it
    /// does. `nil` for an exact hit — the ordinary case, which needs no
    /// remark.
    var locatorReason: String?
    /// That file's contents. `nil` only when this preset configures no notes
    /// at all; a configured-but-absent file reads as `""` so the prompt still
    /// gets its labelled `## Jotted notes` section (see ``notesMissing``).
    var notes: String?
    /// Whether ``notesPath`` was configured but couldn't be read — the
    /// stderr warning's trigger, and the one thing `notes == ""` can't
    /// distinguish from a genuinely empty notes file.
    var notesMissing: Bool = false
    /// Where this preset's summary is written: its expanded `out` template,
    /// or the default sibling naming, and in either case already
    /// disambiguated against the other presets in this run (see
    /// ``disambiguated(_:dependencies:)``).
    var outputURL: URL
  }

  /// Gives every preset in one run its own destination.
  ///
  /// Two presets can resolve to the same path — most easily by both setting
  /// `out = "{notes}"`, which is how a 2026-08-21 user-research call ended up
  /// with a workshop-shaped note: `meeting` wrote the right summary, and
  /// `workshop` overwrote it seconds later. The first preset in run order
  /// keeps the resolved path and each later collider gets its own name
  /// inserted before the extension, the same shape multi-preset runs already
  /// use. Both paths are logged, because a note that silently lands somewhere
  /// other than where its preset asked for is its own kind of loss.
  ///
  /// This is a backstop, not the fix: `--select-preset` is what stops the
  /// on-end chain running several presets over one conversation at all. It
  /// exists so that no run — `--all-presets`, repeated `--preset`, a config
  /// with two presets pointed at one file — can destroy a note it just wrote.
  private static func disambiguated(
    _ plans: [PresetPlan], dependencies: Dependencies
  ) -> [PresetPlan] {
    var claimed: [String: String] = [:]  // standardized path -> the preset holding it
    return plans.map { plan in
      var plan = plan
      guard let holder = claimed[plan.outputURL.standardizedFileURL.path] else {
        claimed[plan.outputURL.standardizedFileURL.path] = plan.preset.name
        return plan
      }
      // The preset's own name first, then `-2`, `-3`… for the pathological
      // case of two presets configured under one name: the loop has to end on
      // a path nobody holds, whatever the config says.
      var candidate = inserting(plan.preset.name, into: plan.outputURL)
      var suffix = 2
      while claimed[candidate.standardizedFileURL.path] != nil {
        candidate = inserting("\(plan.preset.name)-\(suffix)", into: plan.outputURL)
        suffix += 1
      }
      dependencies.log(
        "preset '\(plan.preset.name)': \(plan.outputURL.path) is already the output of preset "
          + "'\(holder)'; writing to \(candidate.path) instead")
      claimed[candidate.standardizedFileURL.path] = plan.preset.name
      plan.outputURL = candidate
      return plan
    }
  }

  /// `<stem>.<name>.<ext>` — the disambiguating shape
  /// ``outputURL(for:preset:isOnlyPreset:)`` already produces, extended to the
  /// arbitrary destinations an `out` template can name. A `.summary.md` tail
  /// is treated as one extension so a disambiguated summary is still named
  /// like every other multi-preset summary.
  private static func inserting(_ name: String, into url: URL) -> URL {
    let directory = url.deletingLastPathComponent()
    let fileName = url.lastPathComponent
    if fileName.hasSuffix(".summary.md") {
      let stem = String(fileName.dropLast(".summary.md".count))
      return directory.appendingPathComponent("\(stem).\(name).summary.md")
    }
    guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
      return directory.appendingPathComponent("\(fileName).\(name)")
    }
    return directory.appendingPathComponent(
      "\(fileName[fileName.startIndex..<dot]).\(name)\(fileName[dot...])")
  }

  /// Everything about this run the note's reader needs to know and cannot see
  /// from the prose: attribution that was inferred or left unresolved
  /// upstream, and jottings that were looked for and not found.
  ///
  /// The upstream half arrives in the transcript's `warnings:` frontmatter,
  /// having been produced at session end by `RosterReconciler`. It was
  /// already being written to a log at the time; the log is not where anyone
  /// looks, which is why a call could be transcribed under the wrong person's
  /// name and be discovered days later by reading the note.
  private static func noteWarnings(
    _ plan: PresetPlan, _ frontmatter: TranscriptFrontmatter
  ) -> [String] {
    var warnings = frontmatter.warnings
    if plan.notesMissing, let notesPath = plan.notesPath {
      warnings.append(
        "no jotted notes were found for this call — searched \(notesPath) and the folders "
          + "beside it. This note was written from the transcript alone; if you did jot "
          + "something, it is still wherever you filed it.")
    }
    if let reason = plan.locatorReason, let notesPath = plan.notesPath {
      warnings.append(
        "jotted notes were matched by search, not by name: used \(notesPath) (\(reason)).")
    }
    return warnings
  }

  /// Inserts an Obsidian callout carrying `warnings` at the top of `body`'s
  /// prose.
  ///
  /// A callout rather than a comment or a frontmatter key because it renders,
  /// in the reader, at the top of the note — the one place a caveat about the
  /// note's reliability is certain to be seen by the person deciding whether
  /// to trust it. A clean run adds nothing at all.
  ///
  /// "Top of the prose", not top of the file: a fold-in preset's model is
  /// instructed to open its output with the note's own `---` frontmatter, and
  /// YAML frontmatter is only frontmatter when it is the first thing in the
  /// file. So a leading block is stepped over and the callout goes directly
  /// after it.
  static func annotate(_ body: String, warnings: [String]) -> String {
    guard !warnings.isEmpty else { return body }
    var lines = ["> [!warning] All Ears"]
    for warning in warnings {
      lines.append("> - \(warning)")
    }
    let callout = lines.joined(separator: "\n")

    guard body.hasPrefix("---\n"),
      let close = body.dropFirst(4).range(of: "\n---\n")
    else {
      return callout + "\n\n" + body
    }
    let headEnd = close.upperBound
    let head = String(body[body.startIndex..<headEnd])
    let rest = String(body[headEnd...])
    return head + "\n" + callout + "\n\n" + rest.drop(while: { $0 == "\n" })
  }

  /// The search context for a preset's `notes` template, assembled from the
  /// transcript's own frontmatter — the same source every other downstream
  /// decision reads, so a manual rerun searches exactly as the daemon's run
  /// did.
  ///
  /// The local participant is filtered out of the name list: `attendees`
  /// marks them `(me)` (see ``TranscriptFrontmatter/attendees``), and a note
  /// about a call is named after the *other* person.
  ///
  /// The edit windows are the daemon's recorded intervals for this session,
  /// never the time this run happens: a note written after the call — by
  /// this pipeline for another call, say — says nothing about this one.
  private static func locatorContext(
    _ expandedPath: String, _ frontmatter: TranscriptFrontmatter, transcriptPaths: [String],
    sessions: [Session]
  ) -> NotesLocator.Context {
    let start = frontmatter.started ?? frontmatter.range.start
    let names = frontmatter.attendees
      .filter { !$0.hasSuffix("(me)") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let own = sessions.first { $0.id == frontmatter.session }
    var windows =
      own?.intervals.map { interval in
        NotesLocator.Window(
          start: interval.start, end: interval.end ?? own?.ended ?? frontmatter.range.end)
      } ?? []
    if windows.isEmpty {
      windows = [NotesLocator.Window(start: start, end: frontmatter.range.end)]
    }
    let claimed = sessions.filter { $0.id != frontmatter.session }.flatMap(\.publishedNotes)
    return NotesLocator.Context(
      expandedPath: expandedPath,
      date: UTCCalendar.isoDate(start),
      names: names,
      windows: windows,
      transcripts: Set(transcriptPaths.compactMap(NotesLocator.transcriptStem)),
      claimed: Set(claimed))
  }

  /// The LLM input. With a companion notes file both halves are labelled, so
  /// a prompt can address each ("fold the jotted notes into a narrative,
  /// using the transcript for detail"). With no notes the transcript is sent
  /// bare, exactly as before — an unlabelled single input needs no heading.
  private static func promptBody(notes: String?, transcript: String) -> String {
    guard let notes else { return transcript }
    return "## Jotted notes\n\n\(notes)\n\n## Transcript\n\n\(transcript)"
  }

  /// The path-template context for this run, read off the input documents'
  /// merged frontmatter — the same context `cleanup` publishes by, so a
  /// preset's `notes`/`out` templates address the same session.
  private static func templateContext(
    _ inputs: Inputs, _ frontmatter: TranscriptFrontmatter
  ) -> PathTemplate.Context {
    PathTemplate.Context(
      outputRoot: inputs.outputRoot,
      start: frontmatter.started ?? frontmatter.range.start,
      weekNumbering: inputs.weekNumbering,
      session: frontmatter.session,
      slug: frontmatter.sources.map(\.pathSafe).joined(separator: "_"),
      title: frontmatter.title,
      fallbackName: URL(fileURLWithPath: inputs.transcriptPaths[0])
        .deletingPathExtension().lastPathComponent)
  }

  /// One transcript rendered for the LLM: a short header naming the
  /// conversation, when it started, and who was in it, then one
  /// `[HH:MM:SS] Speaker: text` line per turn.
  ///
  /// Both halves of that header used to be absent — the body was bare
  /// `Speaker: text` lines and the frontmatter was dropped on the floor — and
  /// a prompt asked to date the conversation had nothing to date it from. The
  /// 2026-08-12 meeting note came back with *"date unknown (check — not
  /// stated in transcript)"* stamped across it, which was true of what the
  /// model received and false of the file it was derived from. Timestamps go
  /// back for the same reason: "they said X early on, then walked it back" is
  /// not recoverable from a wall of undifferentiated lines.
  ///
  /// The speaker roll-call marks whichever speakers were captured on `mic` as
  /// `(me)`. A prompt written for these transcripts otherwise has no way to
  /// tell the note's author from its subject except by guessing at the names,
  /// which is exactly how that same note profiled the wrong participant: a
  /// mislabelled remote track put the local participant's name on the other
  /// person's speech, and nothing in the LLM's input contradicted it. Source
  /// is authoritative where a display name is not.
  ///
  /// The header also names the file this text was read from, so a prompt that
  /// wants to link the transcript can quote a path instead of reconstructing
  /// one. Asked for a link with no path in evidence, a model invents a
  /// plausible-looking one.
  ///
  /// A transcript that is not an ears document gets the `transcript:` line and
  /// its own text, unaltered. Everything else in the header is read off
  /// frontmatter it does not have, and a header line stating a title or a
  /// start time this pipeline had to guess at would be worse than its absence.
  private static func bodyText(_ input: TranscriptInput) -> String {
    guard let document = input.document else {
      return "transcript: \(VaultPath.linkTarget(input.path))\n\n\(input.rawText)"
    }
    let frontmatter = document.frontmatter
    let rangeStart = frontmatter.range.start
    var header: [String] = []
    if let title = frontmatter.title, !title.isEmpty {
      header.append("title: \(title)")
    }
    header.append("started: \(UTCCalendar.iso8601(frontmatter.started ?? rangeStart))")
    // Vault-relative where that resolves: the note this feeds is an Obsidian
    // note, and an absolute path inside a `[[…]]` links to nothing.
    header.append("transcript: \(VaultPath.linkTarget(input.path))")
    // The roster, and separately the speakers actually heard. They are not
    // the same list and the difference matters: `attendees` is who the
    // platform says was on the call — known from the moment they joined, and
    // true whatever happened to the audio — while `speakers` is who the
    // capture managed to attribute turns to. When attribution fails, the
    // second list loses a name the first still has, and a model given only
    // the second will name the call after whoever it *did* resolve. Sending
    // both is what lets it write the right name even then.
    if !frontmatter.attendees.isEmpty {
      header.append("attendees: \(frontmatter.attendees.joined(separator: ", "))")
    }
    let speakers = speakerRollCall(document.segments)
    if !speakers.isEmpty {
      header.append("speakers: \(speakers.joined(separator: ", "))")
    }
    // Verbatim, so the model can hedge the specific claims a degraded run
    // undermines rather than the note as a whole.
    for warning in frontmatter.warnings {
      header.append("warning: \(warning)")
    }

    let turns = document.segments.map { turn in
      "[\(UTCCalendar.timeOfDay(rangeStart.advanced(by: turn.segment.start)))] "
        + "\(turn.speaker): \(turn.segment.text)"
    }
    return (header + [""] + turns).joined(separator: "\n")
  }

  /// The distinct speakers in first-appearance order, each annotated `(me)`
  /// when *any* of its turns came from the `mic` source. "Any" rather than
  /// "all" deliberately: a name landing on both the mic and a remote track is
  /// a capture-side identity bug, and flagging it beats silently picking one
  /// reading of a transcript that contradicts itself.
  ///
  /// Nobody is marked when *every* speaker resolves to the mic, which is the
  /// two cases where the annotation would be a lie: a genuinely single-source
  /// recording (one mic, several people in the room), and a Markdown
  /// transcript parsed without its JSON sidecar, where ``TranscriptParser``
  /// resolves every unmarked turn to `sources.first` as a documented guess.
  /// The mark is only worth making where the source data actually separates
  /// the participants.
  private static func speakerRollCall(_ segments: [TranscriptSegment]) -> [String] {
    var order: [String] = []
    var onMic: Set<String> = []
    var seen: Set<String> = []
    for segment in segments {
      if seen.insert(segment.speaker).inserted { order.append(segment.speaker) }
      if segment.source == micSource { onMic.insert(segment.speaker) }
    }
    guard onMic.count < order.count else { return order }
    return order.map { onMic.contains($0) ? "\($0) (me)" : $0 }
  }

  private static let micSource = SourceID(rawValue: "mic")

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
      rangeRun: first.rangeRun,
      session: first.session,
      // The path-template context, carried forward from the first document:
      // a summary of several transcripts still belongs to the session that
      // one names, and this is what a preset's `notes`/`out` expand against.
      title: first.title,
      started: first.started,
      // Carried forward with the rest of the session context: the roster and
      // the caveats belong to the same call the title and start do, and both
      // are read back out — the roster to find this call's notes and to name
      // the other party, the caveats to warn in the note itself.
      attendees: first.attendees,
      warnings: first.warnings,
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
