import Foundation
import Testing

@testable import EarsCore

@Suite("NotesLocator")
struct NotesLocatorTests {
  // The 2026-08-12 Matthew Barras call: 14:29:50Z–15:18:44Z.
  private static let start = Instant(secondsSinceEpoch: 1_786_544_990)
  private static let end = Instant(secondsSinceEpoch: 1_786_547_924)

  /// The vault as it actually was: the week folder holds a `2026-08-12/`
  /// directory the `notes` template knows nothing about, and the note is
  /// named for "Matt Barras" where the roster says "Matthew Barras".
  private static func makeVault() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("NotesLocatorTests-\(UUID().uuidString)")
    let week = root.appendingPathComponent("daily-notes/2026/08/33")
    let day = week.appendingPathComponent("2026-08-12")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

    // Written during the call — this is the one.
    try write(
      day.appendingPathComponent("2026-08-12 - Matt Barras.md"), modified: start.advanced(by: 2200))
    // Also touched during the call, but names nobody.
    try write(day.appendingPathComponent("Untitled.md"), modified: start.advanced(by: 2100))
    // Earlier calls the same day, saved before this one began.
    try write(
      day.appendingPathComponent("2026-08-12 - Alan Bradburne.md"),
      modified: start.advanced(by: -180))
    try write(
      day.appendingPathComponent("2026-08-12 - Lucas Weidinger.md"),
      modified: start.advanced(by: -1800))
    return root
  }

  private static func write(_ url: URL, modified: Instant) throws {
    try "jottings".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: modified.secondsSinceEpoch)],
      ofItemAtPath: url.path)
  }

  private static func context(_ root: URL, title: String) -> NotesLocator.Context {
    NotesLocator.Context(
      expandedPath: root.appendingPathComponent("daily-notes/2026/08/33/\(title).md").path,
      date: "2026-08-12",
      names: ["Matthew Barras"],
      start: start,
      end: end)
  }

  @Test("the template's own path wins outright when it exists")
  func exactPathWins() throws {
    let root = try Self.makeVault()
    defer { try? FileManager.default.removeItem(at: root) }
    let ideal = root.appendingPathComponent("daily-notes/2026/08/33/2026-08-12 - Matt Barras.md")
    try Self.write(ideal, modified: Self.start)

    let resolution = NotesLocator.locate(Self.context(root, title: "2026-08-12 - Matt Barras"))
    #expect(resolution == .exact(ideal.path))
  }

  /// The whole point: the session was titled `meet wUE9lE2sg5YB` because no
  /// meeting name ever resolved, so the template pointed at a file that never
  /// existed — and the real note was a directory deeper, under a short form of
  /// the attendee's name.
  @Test("a note filed a directory deeper, under a short form of the name, is still found")
  func findsTheNoteTheTemplateMissed() throws {
    let root = try Self.makeVault()
    defer { try? FileManager.default.removeItem(at: root) }

    let resolution = NotesLocator.locate(
      Self.context(root, title: "2026-08-12 - meet wUE9lE2sg5YB"))
    guard case .matched(let path, let reason, let confident) = resolution else {
      Issue.record("expected a match, got \(resolution)")
      return
    }
    #expect(path.hasSuffix("2026-08-12/2026-08-12 - Matt Barras.md"))
    #expect(reason.contains("names a participant"))
    #expect(reason.contains("edited during the call"))
    #expect(confident)
  }

  @Test("a match on edit time alone is not confident")
  func editOnlyMatchIsNotConfident() throws {
    let root = try Self.makeVault()
    defer { try? FileManager.default.removeItem(at: root) }
    // Nobody on this call is named by any file, so only `Untitled.md` and the
    // Matt Barras note carry a signal — and the Matt Barras note is claimed.
    let claimed = root.appendingPathComponent(
      "daily-notes/2026/08/33/2026-08-12/2026-08-12 - Matt Barras.md"
    ).path
    let context = NotesLocator.Context(
      expandedPath: root.appendingPathComponent("daily-notes/2026/08/33/x.md").path,
      date: "2026-08-12", names: ["Priya Raman"], start: Self.start, end: Self.end,
      claimed: [claimed])

    guard case .matched(let path, _, let confident) = NotesLocator.locate(context) else {
      Issue.record("expected a match")
      return
    }
    #expect(path.hasSuffix("Untitled.md"))
    #expect(!confident)
  }

  @Test("a note another session published is never a candidate")
  func claimedNoteIsSkipped() {
    let candidate = NotesLocator.Candidate(
      path: "/v/2026-08-12 - Matthew Barras.md", modified: Self.start.advanced(by: 60))
    let context = NotesLocator.Context(
      expandedPath: "/v/x.md", date: "2026-08-12", names: ["Matthew Barras"],
      start: Self.start, end: Self.end, claimed: ["/v/2026-08-12 - Matthew Barras.md"])

    #expect(NotesLocator.score(candidate, context: context) == 0)
  }

  @Test("a note linking another transcript is skipped; one linking this run's stays eligible")
  func foreignTranscriptLinkIsSkipped() {
    let context = NotesLocator.Context(
      expandedPath: "/v/x.md", date: "2026-08-12", names: ["Matthew Barras"],
      start: Self.start, end: Self.end, transcripts: ["2026-08-12 - Matthew Barras"])
    let foreign = NotesLocator.Candidate(
      path: "/v/2026-08-12 - Matthew Barras.md", modified: Self.start.advanced(by: 60),
      linkedTranscript: "2026-08-12 - Alan Bradburne")
    let own = NotesLocator.Candidate(
      path: "/v/2026-08-12 - Matthew Barras.md", modified: Self.start.advanced(by: 60),
      linkedTranscript: "2026-08-12 - Matthew Barras")

    #expect(NotesLocator.score(foreign, context: context) == 0)
    #expect(NotesLocator.score(own, context: context) > 0)
  }

  /// The 2026-09-21 failure: the previous call's summary was written two
  /// minutes after that call ended, which the old 15-minute grace counted as
  /// an edit during it.
  @Test("an edit after the call, or in a pause, is not an edit during it")
  func editWindowIsTheRecordedIntervals() {
    let pauseStart = Self.start.advanced(by: 600)
    let pauseEnd = Self.start.advanced(by: 1200)
    let context = NotesLocator.Context(
      expandedPath: "/v/x.md", date: "2026-08-12",
      windows: [
        NotesLocator.Window(start: Self.start, end: pauseStart),
        NotesLocator.Window(start: pauseEnd, end: Self.end),
      ])
    func score(_ offset: Double, from base: Instant) -> Int {
      NotesLocator.score(
        NotesLocator.Candidate(path: "/v/2026-08-12 x.md", modified: base.advanced(by: offset)),
        context: context)
    }

    #expect(score(60, from: Self.start) == NotesLocator.editWeight)
    #expect(score(60, from: pauseStart) == 0)
    #expect(score(60, from: pauseEnd) == NotesLocator.editWeight)
    #expect(score(120, from: Self.end) == 0)
  }

  @Test("the linked transcript is read from frontmatter, in any link form")
  func linkedTranscriptParsing() {
    let published = """
      ---
      title: Augustin Applegate
      transcript: "[[Transcripts/2026/09/21/2026-09-21 - Augustin Applegate.md]]"
      ---

      body
      """
    #expect(
      NotesLocator.linkedTranscript(inMarkdown: published) == "2026-09-21 - Augustin Applegate")
    #expect(NotesLocator.linkedTranscript(inMarkdown: "jottings\ntranscript: x") == nil)
    #expect(NotesLocator.transcriptStem("[[2026-09-21 - Ana|Ana]]") == "2026-09-21 - Ana")
    #expect(NotesLocator.transcriptStem("/t/2026-09-21 - Ana.md") == "2026-09-21 - Ana")
  }

  @Test("a note from another day is never this call's notes, however well it scores")
  func staysWithinTheDay() {
    let candidate = NotesLocator.Candidate(
      path: "/vault/daily-notes/2026/08/33/2026-08-11 - Matthew Barras.md",
      modified: Self.start.advanced(by: 600))
    let context = NotesLocator.Context(
      expandedPath: "/vault/daily-notes/2026/08/33/x.md", date: "2026-08-12",
      names: ["Matthew Barras"], start: Self.start, end: Self.end)

    #expect(NotesLocator.score(candidate, context: context) == 0)
  }

  @Test("nothing plausible resolves to nothing, rather than to the nearest file")
  func refusesToGuess() throws {
    let root = try Self.makeVault()
    defer { try? FileManager.default.removeItem(at: root) }
    // A call with a different attendee, held outside every note's edit window.
    let context = NotesLocator.Context(
      expandedPath: root.appendingPathComponent("daily-notes/2026/08/33/x.md").path,
      date: "2026-08-12",
      names: ["Priya Raman"],
      start: Self.start.advanced(by: 100_000),
      end: Self.end.advanced(by: 100_000))

    #expect(NotesLocator.locate(context) == .notFound)
  }

  @Test("two equally plausible notes resolve to neither")
  func refusesToBreakATie() {
    // Overwriting one of two candidate notes on a coin toss is the one
    // outcome worse than not finding either.
    let candidates = [
      NotesLocator.Candidate(path: "/v/2026-08-12 - Ana.md", modified: Self.start.advanced(by: 10)),
      NotesLocator.Candidate(
        path: "/v/2026-08-12 - Ana B.md", modified: Self.start.advanced(by: 20)),
    ]
    let context = NotesLocator.Context(
      expandedPath: "/v/x.md", date: "2026-08-12", names: ["Ana"], start: Self.start, end: Self.end)

    #expect(NotesLocator.best(among: candidates, context: context) == nil)
  }

  @Test("a short form matches its long form, but unrelated names do not")
  func nameTokenMatching() {
    #expect(NotesLocator.tokensMatch("matt", "matthew"))
    #expect(NotesLocator.tokensMatch("barras", "barras"))
    // Same first three letters would be too generous at two characters, and
    // these two share none of them anyway.
    #expect(!NotesLocator.tokensMatch("barras", "bradburne"))
    #expect(!NotesLocator.tokensMatch("al", "alan"))
  }
}
