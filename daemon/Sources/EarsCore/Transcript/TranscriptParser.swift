import Foundation

/// Errors surfaced while parsing a rendered transcript document back into a
/// ``TranscriptDocument``.
public enum TranscriptParsingError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The document doesn't open with the `---\n...\n---\n` frontmatter fence
  /// ``TranscriptRenderer/renderMarkdown(_:)`` always writes.
  case missingFrontmatterFences
  /// A required frontmatter field is missing.
  case missingField(String)
  /// A frontmatter field's value doesn't parse as its expected type.
  case malformedField(field: String, value: String)
  /// The JSON sidecar isn't valid JSON, or doesn't match the sidecar schema.
  case malformedJSON(String)

  public var description: String {
    switch self {
    case .missingFrontmatterFences:
      return "transcript is missing its '---' frontmatter fences"
    case .missingField(let field):
      return "transcript frontmatter is missing required field '\(field)'"
    case .malformedField(let field, let value):
      return "transcript frontmatter field '\(field)' has an unparseable value: '\(value)'"
    case .malformedJSON(let detail):
      return "transcript JSON sidecar is malformed: \(detail)"
    }
  }
}

/// Parses a rendered `.transcript.md` (or `.clean.md`/`.summary.md` — all
/// three share one schema, see ``TranscriptRenderer``) document, and
/// optionally its `.transcript.json` sidecar, back into a
/// ``TranscriptDocument``. `EarsCore/Transcript/` is otherwise
/// write-direction-only (`TranscriptRenderer`/`SidecarJSONRenderer`); this is
/// the read direction `cleanup`/`summarize` need.
///
/// This is deliberately a narrow, hand-written parser matched exactly to
/// ``FrontmatterRenderer``'s and ``SidecarJSONRenderer``'s fixed output shape
/// — not a general YAML/JSON reader — mirroring those renderers' own "not a
/// general encoder" scoping.
///
/// **Known lossy fields:**
/// - Neither the Markdown body nor the JSON sidecar writes
///   `Segment.confidence` (``SidecarJSONRenderer``'s doc comment:
///   "intentionally dropped"). A parsed `Segment.confidence` is therefore
///   always `nil`, regardless of what the original transcription run
///   measured. Any confidence-based decision (e.g. `HighConfidenceSkipPolicy`)
///   has no effect against a re-read, persisted transcript — only at the
///   moment `transcribe` first produces segments.
/// - The JSON sidecar has no `sourceProvenance` field at all
///   (``SidecarJSONRenderer/segmentValue(_:)`` never writes one) — only the
///   Markdown heading's optional `<!-- source: ... -->` comment carries it.
///   ``parse(markdown:jsonSidecar:)`` therefore recovers `sourceProvenance`
///   from the Markdown body even when a JSON sidecar supplies everything
///   else, by merging the two positionally (same segment order both
///   renderers share) — ``parseJSONSidecar(_:)`` called alone cannot recover
///   it and always reports `false`.
/// - Without a `sourceProvenance` marker, the Markdown body alone never
///   records *which* source a turn came from (`MarkdownBodyRenderer` omits
///   the source entirely unless `sourceProvenance` is set). The Markdown-only
///   fallback (`jsonSidecar == nil`) resolves an unmarked turn's source to
///   `frontmatter.sources.first` — correct for the common single-source case,
///   ambiguous (and only a guess) for a genuinely multi-source document with
///   unmarked turns, which needs the JSON sidecar for correct attribution.
///
/// These are limitations of the on-disk format as it exists today, not
/// something this parser works around.
public enum TranscriptParser {
  /// Parses `markdown`'s frontmatter, and its segments from `jsonSidecar` when
  /// given (full fidelity: start/end/words) or, when `jsonSidecar` is `nil`,
  /// reconstructed from the Markdown body alone (reduced fidelity: no
  /// per-segment `end` time or word timings — see
  /// ``parseMarkdownSegments(_:rangeStart:)``).
  public static func parse(markdown: String, jsonSidecar: String? = nil) throws
    -> TranscriptDocument
  {
    let frontmatter = try parseFrontmatter(markdown)
    let fallbackSource = frontmatter.sources.first ?? SourceID("unknown")
    let segments: [TranscriptSegment]
    if let jsonSidecar {
      var jsonSegments = try parseJSONSidecar(jsonSidecar)
      // Overlay sourceProvenance from the Markdown body (see the type doc's
      // "Known lossy fields") — only when the turn counts agree, so a
      // mismatched/hand-edited pair degrades to `false` rather than
      // misattributing flags to the wrong turns.
      if let markdownTurns = try? parseMarkdownSegments(
        markdown, rangeStart: frontmatter.range.start, fallbackSource: fallbackSource),
        markdownTurns.count == jsonSegments.count
      {
        for index in jsonSegments.indices {
          jsonSegments[index].sourceProvenance = markdownTurns[index].sourceProvenance
        }
      }
      segments = jsonSegments
    } else {
      segments = try parseMarkdownSegments(
        markdown, rangeStart: frontmatter.range.start, fallbackSource: fallbackSource)
    }
    return TranscriptDocument(frontmatter: frontmatter, segments: segments)
  }

  // MARK: - Frontmatter

  public static func parseFrontmatter(_ markdown: String) throws -> TranscriptFrontmatter {
    guard markdown.hasPrefix("---\n") else { throw TranscriptParsingError.missingFrontmatterFences }
    let afterOpenFence = markdown.dropFirst(4)
    guard let closeFenceRange = afterOpenFence.range(of: "\n---\n") else {
      throw TranscriptParsingError.missingFrontmatterFences
    }
    let block = afterOpenFence[afterOpenFence.startIndex..<closeFenceRange.lowerBound]

    var fields: [String: String] = [:]
    for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let (key, value) = splitKeyValue(rawLine) else {
        throw TranscriptParsingError.malformedField(field: "?", value: String(rawLine))
      }
      fields[key] = value
    }

    func field(_ name: String) throws -> String {
      guard let value = fields[name] else { throw TranscriptParsingError.missingField(name) }
      return value
    }
    func int(_ name: String, _ raw: String) throws -> Int {
      guard let value = Int(raw) else {
        throw TranscriptParsingError.malformedField(field: name, value: raw)
      }
      return value
    }
    func double(_ name: String, _ raw: String) throws -> Double {
      guard let value = Double(raw) else {
        throw TranscriptParsingError.malformedField(field: name, value: raw)
      }
      return value
    }
    func instant(_ name: String, _ raw: String) throws -> Instant {
      guard let value = ISO8601InstantCodec.parse(raw) else {
        throw TranscriptParsingError.malformedField(field: name, value: raw)
      }
      return value
    }

    let schema = try int("schema", field("schema"))
    guard let kind = TranscriptKind(rawValue: try field("kind")) else {
      throw TranscriptParsingError.malformedField(field: "kind", value: try field("kind"))
    }
    let derivedFrom = fields["derived_from"].map(unquote)
    let preset = fields["preset"].map(unquote)
    let session = try field("session")
    let meeting = fields["meeting"].map(unquote)
    let sources = try splitFlowArray(field("sources")).map { SourceID(unquote($0)) }

    let rangeMapping = try flowMappingFields(field("range"))
    let range = TimeRange(
      start: try instant("range.start", try requireMapping(rangeMapping, "start", "range")),
      end: try instant("range.end", try requireMapping(rangeMapping, "end", "range")))

    let modelMapping = try flowMappingFields(field("model"))
    let model = TranscriptModelInfo(
      name: unquote(try requireMapping(modelMapping, "name", "model")),
      backend: unquote(try requireMapping(modelMapping, "backend", "model")),
      version: unquote(try requireMapping(modelMapping, "version", "model")))

    let diarizationMapping = try flowMappingFields(field("diarization"))
    let diarization = TranscriptDiarizationInfo(
      enabled: try requireMapping(diarizationMapping, "enabled", "diarization") == "true",
      backend: diarizationMapping["backend"].map(unquote))

    let generated = try instant("generated", field("generated"))
    let durationSeconds = try double("duration_seconds", field("duration_seconds"))
    let speechSeconds = try double("speech_seconds", field("speech_seconds"))
    let wordCount = try int("word_count", field("word_count"))
    let vocab = try splitFlowArray(field("vocab")).map(unquote)

    return TranscriptFrontmatter(
      schema: schema,
      kind: kind,
      session: session,
      meeting: meeting,
      sources: sources,
      range: range,
      model: model,
      diarization: diarization,
      generated: generated,
      durationSeconds: durationSeconds,
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: vocab,
      derivedFrom: derivedFrom,
      preset: preset)
  }

  // MARK: - JSON sidecar (full-fidelity segments)

  public static func parseJSONSidecar(_ json: String) throws -> [TranscriptSegment] {
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: Data(json.utf8))
    } catch {
      throw TranscriptParsingError.malformedJSON(error.localizedDescription)
    }
    guard let object = root as? [String: Any], let rawSegments = object["segments"] as? [Any] else {
      throw TranscriptParsingError.malformedJSON("missing top-level 'segments' array")
    }
    return try rawSegments.map(segment(from:))
  }

  private static func segment(from raw: Any) throws -> TranscriptSegment {
    guard let dict = raw as? [String: Any],
      let start = dict["start"] as? Double,
      let end = dict["end"] as? Double,
      let source = dict["source"] as? String,
      let speaker = dict["speaker"] as? String,
      let text = dict["text"] as? String
    else {
      throw TranscriptParsingError.malformedJSON("malformed segment object")
    }
    let words = (dict["words"] as? [Any] ?? []).compactMap(wordTiming(from:))
    return TranscriptSegment(
      source: SourceID(source),
      speaker: speaker,
      segment: Segment(start: start, end: end, text: text, words: words, confidence: nil))
  }

  private static func wordTiming(from raw: Any) -> WordTiming? {
    guard let dict = raw as? [String: Any],
      let text = dict["w"] as? String,
      let start = dict["start"] as? Double,
      let end = dict["end"] as? Double
    else { return nil }
    return WordTiming(text: text, start: start, end: end, confidence: dict["conf"] as? Double)
  }

  // MARK: - Markdown-body fallback (reduced fidelity: no end time/words)

  /// Reconstructs an approximate segment list directly from the Markdown
  /// body when no JSON sidecar is available. Each turn's heading gives only
  /// a `HH:MM:SS` time-of-day for its start (``MarkdownBodyRenderer`` never
  /// writes an end time or word timings) — so every returned `Segment.end`
  /// equals its `start` (zero duration) and `words` is always empty. Callers
  /// that need real durations/word timings must use the JSON sidecar.
  ///
  /// - Parameter fallbackSource: Used for a turn with no `sourceProvenance`
  ///   comment, since the Markdown heading itself carries no source id in
  ///   that case (see the type doc's "Known lossy fields").
  public static func parseMarkdownSegments(
    _ markdown: String, rangeStart: Instant, fallbackSource: SourceID
  ) throws
    -> [TranscriptSegment]
  {
    guard let bodyRange = markdown.range(of: "\n---\n") else { return [] }
    let body = markdown[bodyRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return [] }

    let blocks = body.components(separatedBy: "\n\n")
    return try blocks.map { block -> TranscriptSegment in
      let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard let headingLine = lines.first, headingLine.hasPrefix("## [") else {
        throw TranscriptParsingError.malformedField(field: "segment heading", value: block)
      }
      let text = lines.count > 1 ? String(lines[1]) : ""

      guard let closeBracket = headingLine.firstIndex(of: "]") else {
        throw TranscriptParsingError.malformedField(
          field: "segment heading", value: String(headingLine))
      }
      let timeString = headingLine[
        headingLine.index(headingLine.startIndex, offsetBy: 4)..<closeBracket]
      var rest = headingLine[headingLine.index(after: closeBracket)...].trimmingCharacters(
        in: .whitespaces)

      var source = fallbackSource
      var sourceProvenance = false
      if let commentRange = rest.range(of: "<!-- source: ") {
        let afterMarker = rest[commentRange.upperBound...]
        if let endMarker = afterMarker.range(of: " -->") {
          source = SourceID(String(afterMarker[afterMarker.startIndex..<endMarker.lowerBound]))
          sourceProvenance = true
        }
        rest = String(rest[rest.startIndex..<commentRange.lowerBound]).trimmingCharacters(
          in: .whitespaces)
      }
      let speaker = rest

      let startOffset = try timeOfDayOffset(timeString, rangeStart: rangeStart)
      return TranscriptSegment(
        source: source,
        speaker: speaker,
        segment: Segment(start: startOffset, end: startOffset, text: text),
        sourceProvenance: sourceProvenance)
    }
  }

  /// Resolves a Markdown heading's `HH:MM:SS` time-of-day back to a seconds
  /// offset from `rangeStart`, assuming the same UTC calendar day as
  /// `rangeStart` — `MarkdownBodyRenderer` renders only time-of-day, dropping
  /// the date, so a range crossing midnight cannot be perfectly recovered
  /// from Markdown alone (another reason the JSON sidecar is the
  /// full-fidelity source).
  private static func timeOfDayOffset(_ timeString: Substring, rangeStart: Instant) throws -> Double
  {
    let parts = timeString.split(separator: ":")
    guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2])
    else {
      throw TranscriptParsingError.malformedField(
        field: "segment heading time", value: String(timeString))
    }
    let dayStart = rangeStart.secondsSinceEpoch - Double(Int(rangeStart.secondsSinceEpoch) % 86400)
    let secondOfDay = Double(h * 3600 + m * 60 + s)
    return (dayStart + secondOfDay) - rangeStart.secondsSinceEpoch
  }

  // MARK: - Shared scalar/flow-value helpers, matched to FrontmatterRenderer's grammar

  private static func splitKeyValue(_ line: Substring) -> (key: String, value: String)? {
    guard let colonIndex = line.firstIndex(of: ":") else { return nil }
    let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
    return (key, value)
  }

  /// Splits a `[a, "b:c"]`-shaped flow array's inner elements. Safe here
  /// (not a general YAML list parser) because none of this schema's array
  /// elements (source ids, vocab names) ever contain a literal comma.
  private static func splitFlowArray(_ raw: String) throws -> [String] {
    guard raw.hasPrefix("["), raw.hasSuffix("]") else {
      throw TranscriptParsingError.malformedField(field: "flow array", value: raw)
    }
    let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    guard !inner.isEmpty else { return [] }
    return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// Splits a `{ k: v, k2: v2 }`-shaped flow mapping into its key/value pairs.
  /// Safe here for the same reason as ``splitFlowArray(_:)`` — no value in
  /// this schema's mappings (timestamps, names, bools) contains a comma.
  private static func flowMappingFields(_ raw: String) throws -> [String: String] {
    guard raw.hasPrefix("{"), raw.hasSuffix("}") else {
      throw TranscriptParsingError.malformedField(field: "flow mapping", value: raw)
    }
    let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    guard !inner.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in inner.split(separator: ",") {
      guard let (key, value) = splitKeyValue(pair) else {
        throw TranscriptParsingError.malformedField(field: "flow mapping", value: raw)
      }
      result[key] = value
    }
    return result
  }

  private static func requireMapping(_ mapping: [String: String], _ key: String, _ context: String)
    throws -> String
  {
    guard let value = mapping[key] else {
      throw TranscriptParsingError.missingField("\(context).\(key)")
    }
    return value
  }

  /// Strips one layer of double-quoting and unescapes `\\`/`\"`, matching
  /// ``YAML/quote(_:)``'s minimal escaping exactly. A bare (unquoted) scalar
  /// is returned verbatim.
  private static func unquote(_ value: String) -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
    let inner = value.dropFirst().dropLast()
    var result = ""
    result.reserveCapacity(inner.count)
    var iterator = inner.makeIterator()
    while let character = iterator.next() {
      if character == "\\", let next = iterator.next() {
        result.append(next)
      } else {
        result.append(character)
      }
    }
    return result
  }
}
