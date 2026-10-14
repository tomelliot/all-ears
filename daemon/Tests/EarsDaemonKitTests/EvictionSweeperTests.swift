import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import EarsDaemonKit

/// Tests the daemon-owned, session-driven retention sweep: an ended session's
/// audio (`sessions/<id>/sources/`) is deleted once its deadline passes —
/// `transcript_completed + evict_after_transcript_seconds` when a transcript
/// succeeded, else `ended + max_audio_age_seconds` — while `session.toml` and
/// `events.jsonl` are kept forever, and live sessions are never touched.
@Suite("EvictionSweeper")
struct EvictionSweeperTests {
  private let base = Instant(secondsSinceEpoch: 1_000_000)

  private func makeDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EvictionSweeperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Persists one session: `session.toml` + `events.jsonl` at the global root,
  /// and a `sources/<sid>/asr/` chunk file under the session's directory.
  private func seedSession(
    id: String,
    state: SessionState,
    ended: Instant?,
    transcriptCompleted: Instant?,
    dataRoot: URL
  ) throws {
    let session = Session(
      id: id,
      title: "call",
      state: state,
      started: base,
      ended: ended,
      intervals: [SessionInterval(start: base, end: ended)],
      sources: ["mic"],
      transcriptCompleted: transcriptCompleted)
    try SessionStore.write(session, dataRoot: dataRoot)
    try SessionEventLog.append(
      SessionEventLog.Entry(t: ISO8601InstantCodec.format(base), event: "started"),
      dataRoot: dataRoot, sessionID: id)

    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: id)
    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: sessionRoot, sourceID: "mic")
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: asrDirectory.appendingPathComponent("chunk.m4a"))
  }

  private func sourcesDirectory(id: String, dataRoot: URL) -> URL {
    DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: id)
      .appendingPathComponent("sources")
  }

  private func audioExists(id: String, dataRoot: URL) -> Bool {
    FileManager.default.fileExists(atPath: sourcesDirectory(id: id, dataRoot: dataRoot).path)
  }

  private func makeSweeper(dataRoot: URL, clock: ManualClock) -> EvictionSweeper {
    EvictionSweeper(
      dataRoot: dataRoot,
      clock: clock,
      intervalSeconds: 60,
      evictAfterTranscriptSeconds: 100,
      maxAudioAgeSeconds: 1_000,
      log: { _ in })
  }

  @Test("a transcribed session's audio is deleted at completion + evict_after, and not before")
  func evictsTranscribedSessionAtDeadline() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    let completed = base.advanced(by: 700)
    try seedSession(
      id: "m1", state: .ended, ended: ended, transcriptCompleted: completed, dataRoot: dataRoot)

    let clock = ManualClock(completed.advanced(by: 99))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)

    // One second before the deadline: nothing is deleted.
    await sweeper.sweepOnce()
    #expect(audioExists(id: "m1", dataRoot: dataRoot))

    // At the deadline: the session's audio is gone, its records are kept.
    clock.advance(by: 1)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m1", dataRoot: dataRoot))
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: "m1").path))
    #expect(
      FileManager.default.fileExists(
        atPath: SessionEventLog.fileURL(dataRoot: dataRoot, sessionID: "m1").path))
  }

  @Test("a never-transcribed session's audio survives to ended + max_audio_age, then is deleted")
  func evictsUntranscribedSessionAtHardCap() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    try seedSession(
      id: "m2", state: .ended, ended: ended, transcriptCompleted: nil, dataRoot: dataRoot)

    // Well past the transcript deadline (which doesn't apply — no transcript
    // ever completed) but before the hard cap: audio is retained so a failed
    // transcription can still be retried.
    let clock = ManualClock(ended.advanced(by: 999))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)
    await sweeper.sweepOnce()
    #expect(audioExists(id: "m2", dataRoot: dataRoot))

    clock.advance(by: 1)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m2", dataRoot: dataRoot))
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: "m2").path))
  }

  @Test("a live (non-ended) session is never evicted, no matter how old")
  func neverEvictsLiveSession() async throws {
    let dataRoot = try makeDataRoot()
    try seedSession(
      id: "m3", state: .active, ended: nil, transcriptCompleted: nil, dataRoot: dataRoot)

    let clock = ManualClock(base.advanced(by: 1_000_000))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)
    await sweeper.sweepOnce()

    #expect(audioExists(id: "m3", dataRoot: dataRoot))
  }

  @Test("a session whose audio is already gone sweeps cleanly (idempotent)")
  func sweepIsIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    let completed = base.advanced(by: 700)
    try seedSession(
      id: "m4", state: .ended, ended: ended, transcriptCompleted: completed, dataRoot: dataRoot)

    let clock = ManualClock(completed.advanced(by: 10_000))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m4", dataRoot: dataRoot))
    // A second pass over the same (already-evicted) session is a no-op.
    await sweeper.sweepOnce()
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: "m4").path))
  }

  @Test("repeated passes parse an unchanged session.toml once, and see a write at once")
  func sweepReusesUnchangedDescriptors() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    try seedSession(
      id: "m5", state: .ended, ended: ended, transcriptCompleted: nil, dataRoot: dataRoot)

    let cache = SessionStore.Cache()
    let clock = ManualClock(ended.advanced(by: 500))
    let sweeper = EvictionSweeper(
      dataRoot: dataRoot,
      clock: clock,
      intervalSeconds: 60,
      evictAfterTranscriptSeconds: 100,
      maxAudioAgeSeconds: 1_000,
      descriptorCache: cache,
      log: { _ in })

    // Before any deadline: three passes, one parse (the leak this guards).
    for _ in 0..<3 { await sweeper.sweepOnce() }
    #expect(audioExists(id: "m5", dataRoot: dataRoot))
    #expect(cache.parseCount == 1)

    // The daemon stamps transcript completion through the shared cache: the
    // next pass reads the new descriptor and evicts on the transcript deadline.
    var session = try SessionStore.read(sessionID: "m5", dataRoot: dataRoot)
    session.transcriptCompleted = ended
    try SessionStore.write(session, dataRoot: dataRoot, cache: cache)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m5", dataRoot: dataRoot))
    #expect(cache.parseCount == 2)
  }
}
