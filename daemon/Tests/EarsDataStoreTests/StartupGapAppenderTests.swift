import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-file tests for ``StartupGapAppender`` -- tier-1, simulating a
/// daemon restart across a real `index.jsonl` with an injected ``Instant``
/// standing in for "now" (never the real wall clock).
@Suite("StartupGapAppender")
struct StartupGapAppenderTests {
  private func makeAppender() throws -> IndexAppender {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StartupGapAppenderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return IndexAppender(fileURL: dir.appendingPathComponent("index.jsonl"))
  }

  @Test("a brand-new source (no index yet) appends nothing")
  func newSourceAppendsNothing() async throws {
    let appender = try makeAppender()
    let event = try await StartupGapAppender.detectAndAppend(
      now: Instant(secondsSinceEpoch: 1_000), indexAppender: appender)

    #expect(event == nil)
    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("a restart after downtime appends a gap covering the uncaptured interval")
  func restartAppendsGap() async throws {
    let appender = try makeAppender()
    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a", frames: 1_440_000))

    // Simulate the daemon being down from t=30 to t=200.
    let now = Instant(secondsSinceEpoch: 200)
    let event = try await StartupGapAppender.detectAndAppend(now: now, indexAppender: appender)

    #expect(
      event
        == .gap(
          start: Instant(secondsSinceEpoch: 30), end: Instant(secondsSinceEpoch: 200),
          reason: "daemon_restart"))

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 2)
    #expect(parsed.events.last == event)
  }

  @Test("a clean restart with no elapsed time appends nothing")
  func cleanRestartAppendsNothing() async throws {
    let appender = try makeAppender()
    try await appender.append(
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30),
        file: "chunks/a.m4a", frames: 1_440_000))

    let event = try await StartupGapAppender.detectAndAppend(
      now: Instant(secondsSinceEpoch: 30), indexAppender: appender)

    #expect(event == nil)
    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 1)
  }
}
