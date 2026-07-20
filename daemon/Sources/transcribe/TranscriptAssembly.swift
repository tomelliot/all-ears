import EarsCore

/// One source's ASR output for a `transcribe` run: its raw ``Segment``s,
/// already time-shifted so `start`/`end` are relative to the *overall*
/// requested range rather than to whichever ``AudioSlice`` they came from
/// (each ``Segment`` from a ``Transcriber`` is relative to the audio buffer
/// it decoded, per that type's doc comment -- ``TranscribePipeline`` performs
/// that shift before handing segments here).
struct SourceTranscription {
  var sourceID: SourceID
  var segments: [Segment]
}

/// Builds the final ``TranscriptDocument`` for a `transcribe` run: merges
/// every source's segments onto one shared timeline ordered by time (per
/// `docs/specs/transcribe.md`'s "merge sources on a shared timeline" step),
/// assigns speaker labels, and fills in the frontmatter.
///
/// Pure -- no I/O, no clock read of its own (`generated` is a parameter) --
/// so it's unit-tested directly; ``TranscribePipeline`` is the only caller
/// and owns turning real ``AudioSlice``/``Transcriber`` output into the
/// ``SourceTranscription`` values this takes.
enum TranscriptAssembly {
  /// Speaker label for a source with no diarization stage (not implemented
  /// yet -- see `docs/specs/model-interface.md`'s `Diarizer`
  /// protocol, out of scope for this pass): `mic` maps to `You` per
  /// `docs/data-formats.md`'s speaker-attribution rule; any other source
  /// (a future `app:`/`system`/`browser:` capture) is labelled with its own
  /// raw source id, a defensible placeholder until per-speaker diarization
  /// exists to split a multi-speaker source into `Speaker N` labels.
  static func speakerLabel(for sourceID: SourceID) -> String {
    sourceID == SourceID("mic") ? "You" : sourceID.rawValue
  }

  static func assemble(
    sourceIDs: [SourceID],
    transcriptions: [SourceTranscription],
    requested: TimeRange,
    sessionIdentifier: String,
    model: TranscriptModelInfo,
    generated: Instant,
    speechSeconds: Double
  ) -> TranscriptDocument {
    var turns: [TranscriptSegment] = []
    for transcription in transcriptions {
      for segment in transcription.segments {
        turns.append(
          TranscriptSegment(
            source: transcription.sourceID,
            speaker: speakerLabel(for: transcription.sourceID),
            segment: segment,
            sourceProvenance: false
          ))
      }
    }
    turns.sort { $0.segment.start < $1.segment.start }

    let wordCount = turns.reduce(0) { total, turn in
      let words =
        turn.segment.words.isEmpty
        ? turn.segment.text.split(whereSeparator: \.isWhitespace).count
        : turn.segment.words.count
      return total + words
    }

    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: sessionIdentifier,
      sources: sourceIDs,
      range: requested,
      model: model,
      diarization: TranscriptDiarizationInfo(enabled: false, backend: nil),
      generated: generated,
      durationSeconds: requested.duration,
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: []
    )

    return TranscriptDocument(frontmatter: frontmatter, segments: turns)
  }
}
