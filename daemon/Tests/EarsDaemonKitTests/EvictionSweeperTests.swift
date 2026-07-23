import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import EarsDaemonKit

/// Tests the daemon-owned, meeting-driven retention sweep: an ended meeting's
/// audio (`meetings/<id>/sources/`) is deleted once its deadline passes —
/// `transcript_completed + evict_after_transcript_seconds` when a transcript
/// succeeded, else `ended + max_audio_age_seconds` — while `meeting.toml` and
/// `events.jsonl` are kept forever, and live meetings are never touched.
@Suite("EvictionSweeper")
struct EvictionSweeperTests {
  private let base = Instant(secondsSinceEpoch: 1_000_000)

  private func makeDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EvictionSweeperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Persists one meeting: `meeting.toml` + `events.jsonl` at the global root,
  /// and a `sources/<sid>/asr/` chunk file under the meeting's directory.
  private func seedMeeting(
    id: String,
    state: MeetingState,
    ended: Instant?,
    transcriptCompleted: Instant?,
    dataRoot: URL
  ) throws {
    let meeting = Meeting(
      id: id,
      title: "call",
      state: state,
      started: base,
      ended: ended,
      intervals: [MeetingInterval(start: base, end: ended)],
      sources: ["mic"],
      transcriptCompleted: transcriptCompleted)
    try MeetingStore.write(meeting, dataRoot: dataRoot)
    try MeetingEventLog.append(
      MeetingEventLog.Entry(t: ISO8601InstantCodec.format(base), event: "started"),
      dataRoot: dataRoot, meetingID: id)

    let meetingRoot = DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: id)
    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: meetingRoot, sourceID: "mic")
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: asrDirectory.appendingPathComponent("chunk.m4a"))
  }

  private func sourcesDirectory(id: String, dataRoot: URL) -> URL {
    DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: id)
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

  @Test("a transcribed meeting's audio is deleted at completion + evict_after, and not before")
  func evictsTranscribedMeetingAtDeadline() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    let completed = base.advanced(by: 700)
    try seedMeeting(
      id: "m1", state: .ended, ended: ended, transcriptCompleted: completed, dataRoot: dataRoot)

    let clock = ManualClock(completed.advanced(by: 99))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)

    // One second before the deadline: nothing is deleted.
    await sweeper.sweepOnce()
    #expect(audioExists(id: "m1", dataRoot: dataRoot))

    // At the deadline: the meeting's audio is gone, its records are kept.
    clock.advance(by: 1)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m1", dataRoot: dataRoot))
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: "m1").path))
    #expect(
      FileManager.default.fileExists(
        atPath: MeetingEventLog.fileURL(dataRoot: dataRoot, meetingID: "m1").path))
  }

  @Test("a never-transcribed meeting's audio survives to ended + max_audio_age, then is deleted")
  func evictsUntranscribedMeetingAtHardCap() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    try seedMeeting(
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
        atPath: DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: "m2").path))
  }

  @Test("a live (non-ended) meeting is never evicted, no matter how old")
  func neverEvictsLiveMeeting() async throws {
    let dataRoot = try makeDataRoot()
    try seedMeeting(
      id: "m3", state: .active, ended: nil, transcriptCompleted: nil, dataRoot: dataRoot)

    let clock = ManualClock(base.advanced(by: 1_000_000))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)
    await sweeper.sweepOnce()

    #expect(audioExists(id: "m3", dataRoot: dataRoot))
  }

  @Test("a meeting whose audio is already gone sweeps cleanly (idempotent)")
  func sweepIsIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let ended = base.advanced(by: 600)
    let completed = base.advanced(by: 700)
    try seedMeeting(
      id: "m4", state: .ended, ended: ended, transcriptCompleted: completed, dataRoot: dataRoot)

    let clock = ManualClock(completed.advanced(by: 10_000))
    let sweeper = makeSweeper(dataRoot: dataRoot, clock: clock)
    await sweeper.sweepOnce()
    #expect(!audioExists(id: "m4", dataRoot: dataRoot))
    // A second pass over the same (already-evicted) meeting is a no-op.
    await sweeper.sweepOnce()
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.meetingTomlFile(dataRoot: dataRoot, meetingID: "m4").path))
  }
}
