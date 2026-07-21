import EarsCore
import EarsDataStore
import Foundation

/// `transcribe --file`'s pipeline: transcribe one or more standalone audio
/// files (a `.m4a` voice memo, an exported meeting recording, ...) that never
/// went through the capture daemon's ring buffer.
///
/// The file-input sibling of ``TranscribePipeline``. It shares every leaf that
/// isn't ring-buffer-specific -- the injected ``TranscribePipeline/Dependencies``
/// (clock + ``Transcriber`` factory + `loadOptions`), ``TranscriptAssembly``,
/// ``TranscriptRenderer``, and ``AtomicFileIO`` -- and swaps only the audio
/// source: ``FileAudioReader`` in place of ``SegmentedAudioReader``. It reads
/// no config `data_root`/`output_root` and resolves no time range or session,
/// so it stays a clean peer of the range-resolving pipeline rather than a
/// branch tangled through it.
///
/// Each `--file` is transcribed *independently* into its own transcript
/// (two files two minutes apart are two recordings, not two mics of one
/// meeting), written next to the input as `<name>.transcript.md` plus the
/// `.transcript.json` sidecar -- or to `--out` when exactly one file is given.
enum TranscribeFilePipeline {
  struct Inputs: Sendable {
    var files: [String]
    /// `--out`: the Markdown path for the sole input; only valid with exactly
    /// one `--file` (the sidecar swaps the extension to `.json`).
    var out: String?
  }

  static func run(
    inputs: Inputs,
    backendName: String,
    dependencies: TranscribePipeline.Dependencies,
    targetSampleRate: Int = 16000,
    fileReader: FileAudioReader = FileAudioReader()
  ) async -> Int32 {
    guard !inputs.files.isEmpty else {
      dependencies.writeStderr("error: at least one --file is required")
      return 1
    }
    // `--out` names a single path, so it can't disambiguate more than one
    // input -- a precise error rather than silently writing every file to the
    // same place.
    if inputs.out != nil, inputs.files.count > 1 {
      dependencies.writeStderr("error: --out cannot be combined with multiple --file inputs")
      return 1
    }

    // Fail fast on a missing file before loading the (expensive) ASR model,
    // matching `TranscribePipeline`'s unknown-source check.
    for path in inputs.files {
      guard FileManager.default.fileExists(atPath: path) else {
        dependencies.writeStderr("error: no such file: \(path)")
        return 1
      }
    }

    // One model load serves every file, exactly as `TranscribePipeline` loads
    // once for every source.
    let transcriber: any Transcriber
    do {
      transcriber = try dependencies.transcriberFactory()
      try transcriber.load(dependencies.loadOptions)
    } catch {
      dependencies.writeStderr("error: failed to load transcriber: \(error)")
      return 1
    }
    let modelInfo = TranscriptModelInfo(
      name: transcriber.info.name, backend: backendName, version: transcriber.info.version)

    for path in inputs.files {
      let code = transcribeFile(
        path: path, out: inputs.out, targetSampleRate: targetSampleRate,
        transcriber: transcriber, modelInfo: modelInfo, fileReader: fileReader,
        dependencies: dependencies)
      guard code == 0 else { return code }
    }
    return 0
  }

  private static func transcribeFile(
    path: String,
    out: String?,
    targetSampleRate: Int,
    transcriber: any Transcriber,
    modelInfo: TranscriptModelInfo,
    fileReader: FileAudioReader,
    dependencies: TranscribePipeline.Dependencies
  ) -> Int32 {
    let fileURL = URL(fileURLWithPath: path)
    // A file has no capture time; anchor its synthetic timeline at zero and
    // place every slice-relative segment back onto it against the same anchor,
    // mirroring `TranscribePipeline`'s requested-range-relative shift.
    let anchor = Instant(secondsSinceEpoch: 0)

    let slices: [AudioSlice]
    do {
      slices = try fileReader.slices(
        fileURL: fileURL, targetSampleRate: targetSampleRate, anchor: anchor)
    } catch {
      dependencies.writeStderr("error: failed to read audio from '\(path)': \(error)")
      return 1
    }

    let sourceID = SourceID(fileURL.deletingPathExtension().lastPathComponent)
    var segments: [Segment] = []
    var speechSeconds: Double = 0
    for slice in slices {
      speechSeconds += slice.audio.duration
      let sliceOffset = slice.range.start.interval(since: anchor)
      do {
        let sliceSegments = try transcriber.transcribe(slice.audio, context: TranscribeContext())
        for segment in sliceSegments {
          segments.append(shifted(segment, by: sliceOffset))
        }
      } catch {
        dependencies.writeStderr("error: transcription failed for '\(path)': \(error)")
        return 1
      }
    }

    let duration = slices.last.map { $0.range.end.interval(since: anchor) } ?? 0
    let requested = TimeRange(start: anchor, end: anchor.advanced(by: duration))
    let generated = dependencies.clock.now()
    let document = TranscriptAssembly.assemble(
      sourceIDs: [sourceID],
      transcriptions: [SourceTranscription(sourceID: sourceID, segments: segments)],
      requested: requested,
      sessionIdentifier: sourceID.rawValue,
      model: modelInfo,
      generated: generated,
      speechSeconds: speechSeconds)

    let paths = outputPaths(for: fileURL, explicitOut: out)
    do {
      let markdown = TranscriptRenderer.renderMarkdown(document)
      try AtomicFileIO.writeAtomically(to: paths.markdown) { tempURL in
        try markdown.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
      let json = TranscriptRenderer.renderJSON(document)
      try AtomicFileIO.writeAtomically(to: paths.sidecar) { tempURL in
        try json.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
    } catch {
      dependencies.writeStderr("error: failed to write transcript for '\(path)': \(error)")
      return 1
    }

    dependencies.log(
      "run.summary: file=\(fileURL.lastPathComponent) segments=\(document.segments.count) "
        + "words=\(document.frontmatter.wordCount) speech_seconds=\(speechSeconds) "
        + "output=\(paths.markdown.path)")
    return 0
  }

  /// Where a file's transcript lands: `--out` verbatim (single-file only, the
  /// sidecar derived by swapping the extension), otherwise
  /// `<input-dir>/<input-name>.transcript.md` and the sibling `.transcript.json`,
  /// so the transcript sits beside the recording it came from.
  private static func outputPaths(for fileURL: URL, explicitOut: String?)
    -> OutputPathResolution.Paths
  {
    if let explicitOut, !explicitOut.isEmpty {
      let markdown = URL(fileURLWithPath: explicitOut)
      let sidecar = markdown.deletingPathExtension().appendingPathExtension("json")
      return OutputPathResolution.Paths(markdown: markdown, sidecar: sidecar)
    }
    let directory = fileURL.deletingLastPathComponent()
    let base = fileURL.deletingPathExtension().lastPathComponent
    return OutputPathResolution.Paths(
      markdown: directory.appendingPathComponent("\(base).transcript.md"),
      sidecar: directory.appendingPathComponent("\(base).transcript.json"))
  }

  /// Shifts a slice-relative ``Segment`` (and its words) onto the file's
  /// timeline. Identical in intent to ``TranscribePipeline``'s own shift; a
  /// tiny local copy keeps the two pipelines decoupled.
  private static func shifted(_ segment: Segment, by offset: Double) -> Segment {
    var result = segment
    result.start += offset
    result.end += offset
    result.words = segment.words.map { word in
      var shiftedWord = word
      shiftedWord.start += offset
      shiftedWord.end += offset
      return shiftedWord
    }
    return result
  }
}
