import Foundation
import Yams

/// Finds the note a user was already jotting into during a call, when the
/// path a `[[summarize.preset]]`'s `notes` template constructs isn't where
/// they actually put it.
///
/// A path template is a fine way to *write* a file and a poor way to *find*
/// one. `notes` is doing the second job: it is an exact-match lookup for a
/// file a human created and named, keyed on a string a machine generated on
/// the other side of the call. Anything that moves either side — a session
/// whose title never resolved past the platform's meeting id, a vault whose
/// filing convention grew a directory level, a note named "Matt Barras" for
/// an attendee the roster calls "Matthew Barras" — misses, and a miss is
/// silent: the fold-in prompt runs against an empty notes section and the
/// jottings are simply absent from the note that replaces them.
///
/// So the template stays the ideal, and this widens it to a search when the
/// ideal isn't there. Every signal it scores on is one a person would use to
/// recognise their own note:
///
/// - it is filed under the **right day**, whether that is in the filename or
///   in a directory component;
/// - its name mentions **someone who was on the call**, matched loosely
///   enough that "Matt" finds "Matthew";
/// - it was **edited while the call was happening**, measured against the
///   call's recorded intervals and nothing else. A grace period after the
///   call used to stretch this window, and summaries are written in exactly
///   that period: one call's published note read as edited during the next.
///
/// Two kinds of file are never candidates, because ears wrote them and a
/// change time on them says nothing about a person taking notes:
///
/// - a note another session **claimed** — one its summarize run published;
/// - a note whose frontmatter **links a different transcript**, which is what
///   every published summary carries, claimed or not (a manual rerun records
///   no claim).
///
/// Nothing is scored on being *near* the constructed path beyond sharing its
/// directory subtree, and a candidate with no positive signal is not
/// returned. An unmatched note leaves the run exactly where it was before
/// this type existed; a *wrongly* matched one would overwrite a note about
/// something else, so silence is the only safe failure.
public enum NotesLocator {

  /// What the search concluded.
  public enum Resolution: Sendable, Hashable {
    /// The template's own path exists. No searching happened.
    case exact(String)
    /// A different file scored well enough to be this call's notes.
    /// ``reason`` explains why, for the warning that accompanies using it.
    /// `confident` is `true` when the filename names someone on the call. A
    /// match on edit time alone is not confident: the caller reads it as
    /// notes but does not write over it, so a wrong match costs an extra
    /// file rather than someone else's note.
    case matched(String, reason: String, confident: Bool)
    /// Nothing plausible. The caller proceeds with no notes, as before.
    case notFound
  }

  /// Everything the search matches against, all of it already known to
  /// `summarize` from the transcript's frontmatter.
  public struct Context: Sendable, Hashable {
    /// The path the `notes` template expanded to — the ideal, and the root of
    /// the subtree searched when it isn't there.
    public var expandedPath: String
    /// The session's day as `YYYY-MM-DD`, the filing key the vault is
    /// organised by.
    public var date: String
    /// Names to look for in a filename. The local participant is deliberately
    /// **not** among them: a note about a call is named after the other
    /// person, so matching on your own name would only ever fire on notes
    /// about something else.
    public var names: [String]
    /// When the call was recorded: the daemon's session intervals, which
    /// leave out paused stretches. A note modified inside one was almost
    /// certainly being written during the call. Empty disables the signal.
    public var windows: [Window]
    /// Filename stems of the transcripts this run summarizes. A candidate
    /// whose frontmatter links one of these is this call's own published
    /// note (a rerun) and stays eligible; one linking anything else is not.
    public var transcripts: Set<String>
    /// Absolute paths of notes other sessions published. Never candidates.
    public var claimed: Set<String>

    public init(
      expandedPath: String, date: String, names: [String] = [], windows: [Window] = [],
      transcripts: Set<String> = [], claimed: Set<String> = []
    ) {
      self.expandedPath = expandedPath
      self.date = date
      self.names = names
      self.windows = windows
      self.transcripts = transcripts
      self.claimed = claimed
    }

    /// One window from `start` to `end`, for a call with no pause.
    public init(
      expandedPath: String, date: String, names: [String] = [], start: Instant, end: Instant,
      transcripts: Set<String> = [], claimed: Set<String> = []
    ) {
      self.init(
        expandedPath: expandedPath, date: date, names: names,
        windows: [Window(start: start, end: end)], transcripts: transcripts, claimed: claimed)
    }
  }

  /// A stretch of the call, both ends inclusive.
  public struct Window: Sendable, Hashable {
    public var start: Instant
    public var end: Instant

    public init(start: Instant, end: Instant) {
      self.start = start
      self.end = end
    }

    func contains(_ instant: Instant) -> Bool { instant >= start && instant <= end }
  }

  /// One file the search is considering.
  public struct Candidate: Sendable, Hashable {
    public var path: String
    public var modified: Instant?
    /// The filename stem of the transcript the file's frontmatter
    /// `transcript:` links, when it has one — the mark of a published note.
    public var linkedTranscript: String?

    public init(path: String, modified: Instant? = nil, linkedTranscript: String? = nil) {
      self.path = path
      self.modified = modified
      self.linkedTranscript = linkedTranscript
    }
  }

  /// How far below the template path's own directory to look. One level
  /// covers the case that prompted this — a vault that files a day's notes in
  /// a `2026-08-12/` folder the template doesn't know about — without turning
  /// a per-week directory into a scan of the whole vault.
  public static let searchDepth = 2

  /// Weight of "this filename names someone who was on the call", per name
  /// token matched. Above ``editWeight`` because a name is *about* the call's
  /// subject, where an edit time is only circumstantial — a note touched
  /// mid-call may still be about something else entirely.
  public static let nameTokenWeight = 2
  /// Weight of "this file was edited during the call".
  public static let editWeight = 1

  /// Resolves `context`'s notes path against the filesystem.
  public static func locate(
    _ context: Context, fileManager: FileManager = .default
  ) -> Resolution {
    if fileManager.fileExists(atPath: context.expandedPath) {
      return .exact(context.expandedPath)
    }
    let root = URL(fileURLWithPath: context.expandedPath).deletingLastPathComponent()
    let candidates = markdownFiles(under: root, fileManager: fileManager)
    guard let best = best(among: candidates, context: context) else { return .notFound }
    return .matched(
      best.path, reason: reason(for: best, context: context),
      confident: nameScore(best, context: context) > 0)
  }

  /// The highest-scoring candidate, or `nil` when none carries a positive
  /// signal or two tie at the top.
  ///
  /// A tie is treated as no answer rather than broken arbitrarily: two
  /// equally plausible notes mean the evidence does not identify one, and
  /// picking either would overwrite a file on a coin toss.
  public static func best(among candidates: [Candidate], context: Context) -> Candidate? {
    let scored =
      candidates
      .map { (candidate: $0, score: score($0, context: context)) }
      .filter { $0.score > 0 }
      .sorted { $0.score > $1.score }
    guard let top = scored.first else { return nil }
    if scored.count > 1, scored[1].score == top.score { return nil }
    return top.candidate
  }

  /// `candidate`'s total score against `context`; `0` means "no reason to
  /// think this is the note".
  public static func score(_ candidate: Candidate, context: Context) -> Int {
    // Filed under the right day is a precondition, not a score: a note from
    // another day is not this call's notes however well it scores otherwise.
    guard candidate.path.contains(context.date) else { return 0 }
    guard isEligible(candidate, context: context) else { return 0 }
    return nameScore(candidate, context: context) + editScore(candidate, context: context)
  }

  private static func nameScore(_ candidate: Candidate, context: Context) -> Int {
    let fileTokens = tokens(in: stem(of: candidate.path))
    guard !fileTokens.isEmpty else { return 0 }
    var matched = 0
    for name in context.names {
      for nameToken in tokens(in: name)
      where fileTokens.contains(where: { tokensMatch($0, nameToken) }) {
        matched += 1
      }
    }
    return matched * nameTokenWeight
  }

  /// `false` for a note ears published for a different call: claimed by
  /// another session, or linking a transcript this run is not summarizing.
  private static func isEligible(_ candidate: Candidate, context: Context) -> Bool {
    if context.claimed.map(resolved).contains(resolved(candidate.path)) { return false }
    if let linked = candidate.linkedTranscript, !context.transcripts.contains(linked) {
      return false
    }
    return true
  }

  /// `path` with symlinks resolved, so `/var/…` and `/private/var/…` compare
  /// equal.
  private static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private static func editScore(_ candidate: Candidate, context: Context) -> Int {
    guard let modified = candidate.modified else { return 0 }
    return context.windows.contains { $0.contains(modified) } ? editWeight : 0
  }

  /// Human-readable justification for a fuzzy match, so the warning that
  /// carries it says which signals fired rather than only that something did.
  private static func reason(for candidate: Candidate, context: Context) -> String {
    var signals: [String] = []
    if nameScore(candidate, context: context) > 0 { signals.append("names a participant") }
    if editScore(candidate, context: context) > 0 { signals.append("edited during the call") }
    if signals.isEmpty { signals.append("filed under \(context.date)") }
    return signals.joined(separator: ", ")
  }

  /// Two name tokens refer to the same person's name, allowing for the short
  /// forms people file notes under: exact ignoring case, or one a prefix of
  /// the other at three characters or more ("Matt" ↔ "Matthew").
  ///
  /// Three is the shortest prefix that is worth anything — at two, "Al"
  /// matches "Alan" and "Alexandra" alike, and initials would match nearly
  /// everyone.
  static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    let shorter = lhs.count <= rhs.count ? lhs : rhs
    let longer = lhs.count <= rhs.count ? rhs : lhs
    guard shorter.count >= 3 else { return false }
    return longer.hasPrefix(shorter)
  }

  /// Lowercased word tokens, splitting on everything that isn't a letter or
  /// digit, with the one-and-two-character noise dropped (`-`, `&`, `of`).
  static func tokens(in value: String) -> [String] {
    value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 3 }
  }

  /// A path's filename without its extension.
  private static func stem(of path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  /// Every `.md` file at or below `root`, to ``searchDepth``.
  ///
  /// Hidden directories are skipped: `.obsidian` and `.trash` hold a vault's
  /// own machinery and a user's deleted notes, and neither is ever the file
  /// being looked for.
  private static func markdownFiles(under root: URL, fileManager: FileManager) -> [Candidate] {
    var found: [Candidate] = []
    var frontier = [(url: root, depth: 0)]
    while let (directory, depth) = frontier.popLast() {
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for entry in entries {
        let values = try? entry.resourceValues(forKeys: [
          .isDirectoryKey, .contentModificationDateKey,
        ])
        if values?.isDirectory == true {
          if depth + 1 < searchDepth { frontier.append((entry, depth + 1)) }
          continue
        }
        guard entry.pathExtension.lowercased() == "md" else { continue }
        found.append(
          Candidate(
            path: entry.path,
            modified: values?.contentModificationDate.map {
              Instant(secondsSinceEpoch: $0.timeIntervalSince1970)
            },
            linkedTranscript: linkedTranscript(in: entry)))
      }
    }
    return found
  }

  /// The filename stem of the transcript `url`'s frontmatter links through
  /// `transcript:`, or `nil` when it has no frontmatter or no such key.
  ///
  /// Compared by stem, not path: Obsidian may rewrite a link to its
  /// shortest unique form (`[[2026-09-21 - Ana]]`), and the stem is what
  /// survives that.
  static func linkedTranscript(in url: URL) -> String? {
    guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return linkedTranscript(inMarkdown: markdown)
  }

  static func linkedTranscript(inMarkdown markdown: String) -> String? {
    guard markdown.hasPrefix("---\n") else { return nil }
    let body = markdown.dropFirst(4)
    guard let close = body.range(of: "\n---") else { return nil }
    guard
      let mapping = try? Yams.load(yaml: String(body[..<close.lowerBound])) as? [String: Any],
      let link = mapping["transcript"] as? String
    else { return nil }
    return transcriptStem(link)
  }

  /// `[[Transcripts/2026/09/21/2026-09-21 - Ana.md|Ana]]` →
  /// `2026-09-21 - Ana`. Also accepts a bare path.
  public static func transcriptStem(_ link: String) -> String? {
    var target = link.trimmingCharacters(in: .whitespaces)
    if target.hasPrefix("[["), target.hasSuffix("]]") {
      target = String(target.dropFirst(2).dropLast(2))
    }
    if let pipe = target.firstIndex(of: "|") { target = String(target[..<pipe]) }
    if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
    let stem = stem(of: target)
    return stem.isEmpty ? nil : stem
  }
}
