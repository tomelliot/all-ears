import EarsCore

/// Finds browser sources that carry the local participant's own audio — a
/// second recording of what `mic` already holds.
///
/// The browser taps remote streams, but Meet's WebAudio graph also carries the
/// user's outgoing audio, and the extension's provenance check cannot always
/// tell the two apart (`browser/lib/track-provenance.ts`: a processed local
/// track has no lineage and adopts as unknown). When that check misses, every
/// sentence the user says lands in the transcript once from `mic` and once per
/// adopted copy, and the roster reconciler then names the copies after the
/// call's other participant. The 2026-11-19 session had three such copies.
///
/// This is the daemon's backstop, and it tests the claim directly: a source is
/// a copy of the mic when it repeats nearly everything the mic said. Measured
/// over 78 stored sessions, the copies repeated 94–97% of the mic's words;
/// no genuine remote track with a usable sample repeated more than 44%.
///
/// The measure is deliberately one-sided — the share of the *mic's* words
/// found in the source, not the reverse. A remote participant whose voice
/// bleeds from the user's speakers into the mic is fully contained in the mic,
/// but does not contain the user's own speech, so it does not qualify.
///
/// Pure: segments in, source ids out.
enum MicDuplicateSources {
  /// Share of the mic's words a source must repeat to count as a copy.
  static let coverageThreshold = 0.7

  /// Fewest mic words the comparison needs. Below this a handful of shared
  /// filler words ("yeah", "okay") moves the share too far to act on.
  static let minimumMicWords = 100

  /// How far apart, in seconds, two segments may sit and still be compared.
  /// Sources are clocked independently and segmented at different pauses.
  static let alignmentToleranceSeconds = 3.0

  /// The browser sources to leave out of the transcript.
  ///
  /// Never returns every speech-carrying browser source: if nothing remote
  /// would remain, the evidence fits a quiet user on speakers as well as it
  /// fits a copy, and dropping a real participant loses the call.
  static func detect(in transcriptions: [SourceTranscription]) -> [SourceID] {
    guard let mic = transcriptions.first(where: { $0.sourceID == SourceID("mic") }) else {
      return []
    }
    let micSegments = mic.segments.map(Tokenized.init).filter { !$0.words.isEmpty }
    guard !micSegments.isEmpty else { return [] }

    var spoken = 0
    var duplicates: [SourceID] = []
    for transcription in transcriptions where transcription.sourceID.sourceClass == .browser {
      let segments = transcription.segments.map(Tokenized.init).filter { !$0.words.isEmpty }
      guard !segments.isEmpty else { continue }
      spoken += 1
      if let coverage = micCoverage(mic: micSegments, by: segments),
        coverage >= coverageThreshold
      {
        duplicates.append(transcription.sourceID)
      }
    }
    return duplicates.count < spoken ? duplicates : []
  }

  /// The share of the mic's words, spoken while `source` was live, that
  /// `source` also carries in a segment at about the same time. `nil` when the
  /// mic said too little in that span to judge.
  static func micCoverage(mic: [Tokenized], by source: [Tokenized]) -> Double? {
    guard let first = source.map(\.start).min(), let last = source.map(\.end).max() else {
      return nil
    }
    var total = 0
    var matched = 0
    for segment in mic where segment.end >= first && segment.start <= last {
      var pool: [Substring: Int] = [:]
      for other in source
      where other.end + alignmentToleranceSeconds >= segment.start
        && other.start - alignmentToleranceSeconds <= segment.end
      {
        for word in other.words { pool[word, default: 0] += 1 }
      }
      total += segment.words.count
      for word in segment.words {
        if let available = pool[word], available > 0 {
          pool[word] = available - 1
          matched += 1
        }
      }
    }
    guard total >= minimumMicWords else { return nil }
    return Double(matched) / Double(total)
  }

  /// A segment reduced to its comparable words: lowercased, punctuation
  /// stripped, so "Yeah, exactly." and "yeah exactly" agree.
  struct Tokenized {
    var start: Double
    var end: Double
    var words: [Substring]

    init(_ segment: Segment) {
      start = segment.start
      end = segment.end
      words = segment.text.lowercased()
        .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
    }
  }

  /// How much more a copy must say than the mic before it replaces the mic.
  static let replacementWordRatio = 1.25

  /// What to do about the copies found by ``detect(in:)``.
  struct Resolution: Equatable {
    /// Sources whose turns stay out of the transcript.
    var dropped: [SourceID] = []
    /// A copy to use as the user's own voice in place of `mic`, over
    /// ``replacedSpan``. Set when the copy carries clearly more speech than
    /// the mic does: the mic's voice-activity detection can miss most of a
    /// quiet microphone (the 2026-11-19 mic kept 194 s of speech against 788 s
    /// on the copy), and then the copy is the better record of the user.
    var micReplacement: SourceID?
    /// The span the replacement covers; mic turns starting inside it are
    /// dropped, mic turns outside it are kept.
    var replacedSpan: ClosedRange<Double>?

    var isEmpty: Bool { dropped.isEmpty && micReplacement == nil }
  }

  /// Decides between the mic and its copies: normally the copies are dropped;
  /// when the richest copy says at least ``replacementWordRatio`` times what
  /// the mic says over the same span, that copy stands in for the mic.
  static func resolve(_ transcriptions: [SourceTranscription]) -> Resolution {
    let duplicates = detect(in: transcriptions)
    guard !duplicates.isEmpty,
      let mic = transcriptions.first(where: { $0.sourceID == SourceID("mic") })
    else { return Resolution() }

    func words(_ segments: [Segment]) -> Int {
      segments.reduce(0) { $0 + Tokenized($1).words.count }
    }
    var best: (source: SourceID, words: Int, span: ClosedRange<Double>)?
    for transcription in transcriptions where duplicates.contains(transcription.sourceID) {
      guard let first = transcription.segments.map(\.start).min(),
        let last = transcription.segments.map(\.end).max()
      else { continue }
      let count = words(transcription.segments)
      if best == nil || count > best!.words {
        best = (transcription.sourceID, count, first...last)
      }
    }
    guard let best else { return Resolution(dropped: duplicates) }
    let micWords = words(mic.segments.filter { best.span.contains($0.start) })
    guard Double(best.words) >= Double(micWords) * replacementWordRatio else {
      return Resolution(dropped: duplicates)
    }
    return Resolution(
      dropped: duplicates.filter { $0 != best.source },
      micReplacement: best.source, replacedSpan: best.span)
  }

  /// The transcript warnings for a resolution.
  static func warnings(for resolution: Resolution) -> [String] {
    var warnings: [String] = []
    let count = resolution.dropped.count
    if count > 0 {
      warnings.append(
        "speaker attribution: left out \(count) audio \(count == 1 ? "track" : "tracks") that "
          + "repeated your own microphone")
    }
    if resolution.micReplacement != nil {
      warnings.append(
        "speaker attribution: your turns come from the browser's copy of your audio — the "
          + "microphone recording captured less of your speech")
    }
    return warnings
  }
}
