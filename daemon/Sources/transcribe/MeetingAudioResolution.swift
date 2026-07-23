import EarsDataStore

/// Which of a meeting's two audio stores a given source was read from, per
/// all-ears issue #20's "decide and document the intended lookup order per
/// source class".
///
/// A meeting's audio can live in two places:
/// - **`.meeting`** — the per-meeting copy under `meetings/<id>/sources/<source>/`,
///   written while the meeting names the source. This is the *authoritative*
///   copy for an ended meeting: retention evicts the global ring independently,
///   so per-meeting chunks can outlive the ring's, and are never stale relative
///   to the meeting's own window.
/// - **`.ring`** — the global rolling buffer under `<data-root>/sources/<source>/`.
///   The only copy for a source that has no per-meeting directory (e.g. the
///   locally-captured `mic`, which the ring records for whichever meeting is
///   active), so the meeting path falls back to it there.
enum MeetingAudioStore: String, Sendable, Equatable {
  case meeting
  case ring

  /// The label recorded in transcript frontmatter (`audio_stores`) and logs.
  var label: String { rawValue }
}

/// Pure store-selection and empty-diagnosis logic for `transcribe --meeting`.
/// The I/O (probing each candidate store, decoding the chosen one) lives in
/// ``TranscribePipeline``; this only decides *which* store to prefer and, when
/// a read comes back empty, *why* — so both rules are unit-testable without a
/// data root on disk.
enum MeetingAudioResolution {
  /// Chooses which store to read a source's meeting audio from, given a probe
  /// of each candidate. The rule, matching issue #20's acceptance criteria
  /// ("reads per-meeting chunks when they exist, falling back to the ring store
  /// only where they don't"):
  ///
  /// 1. Prefer the per-meeting store when it holds chunks in range — the
  ///    authoritative copy for an ended meeting.
  /// 2. Otherwise fall back to the ring store when *it* holds chunks in range.
  /// 3. If neither holds chunks but a store directory exists, keep the
  ///    per-meeting store when present (still authoritative — an empty result
  ///    there is the honest answer), else the ring.
  /// 4. If neither store has this source at all, return `nil` (store missing).
  static func chooseStore(
    meeting: SegmentedAudioReader.RangeProbe, ring: SegmentedAudioReader.RangeProbe
  ) -> MeetingAudioStore? {
    if meeting.sourceExists && meeting.chunksInRange > 0 { return .meeting }
    if ring.sourceExists && ring.chunksInRange > 0 { return .ring }
    if meeting.sourceExists { return .meeting }
    if ring.sourceExists { return .ring }
    return nil
  }

  /// A one-line, human-readable reason a source contributed no speech to a
  /// `segments=0` run, from the chosen store's read report. `nil` when the
  /// source *did* produce slices (it is not part of the empty explanation).
  ///
  /// - Parameter storeExists: whether any store was chosen for this source at
  ///   all; `false` yields `"store missing"`.
  static func emptyReason(
    storeExists: Bool, chunksInRange: Int, speechIntervals: Int, sliceCount: Int
  ) -> String? {
    guard sliceCount == 0 else { return nil }
    if !storeExists { return "store missing" }
    if chunksInRange == 0 { return "no chunks in range" }
    if speechIntervals == 0 { return "chunks but no speech intervals" }
    // Speech spans existed but the natural-pause segmenter produced no audio
    // windows (e.g. spans clipped entirely outside the range's usable audio).
    return "speech intervals produced no audio windows"
  }
}
