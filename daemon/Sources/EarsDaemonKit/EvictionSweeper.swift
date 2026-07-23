import EarsCore
import EarsDataStore
import Foundation

/// The daemon's retention enforcer: a single, timer-driven pass that deletes
/// each **ended meeting's** audio (`meetings/<id>/sources/`) once its
/// retention deadline passes, per `[earsd.retention]`:
///
/// - transcript completed successfully → deleted at
///   `transcript_completed + evict_after_transcript_seconds`;
/// - transcript never completed → retained (so a failed run can be retried)
///   until `ended + max_audio_age_seconds`, then deleted regardless.
///
/// The first deadline always wins arithmetically when both exist
/// (`completed + evict_after < ended + max_age` for the shipped defaults), so
/// no explicit whichever-first logic is needed. `meeting.toml` and
/// `events.jsonl` are never deleted — the meeting's record outlives its
/// audio. Live (non-ended) meetings are never touched, no matter how old.
///
/// Retention is a per-meeting directory delete because audio is
/// meeting-scoped: everything a meeting recorded lives under its own
/// `sources/` tree, so eviction needs no chunk-level bookkeeping, no index
/// rewrite, and no coordination with a live `CaptureActor` (an ended
/// meeting's actors are already torn down).
public actor EvictionSweeper {
  private let dataRoot: URL
  private let clock: any NowProviding
  private let intervalSeconds: Double
  private let evictAfterTranscriptSeconds: Double
  private let maxAudioAgeSeconds: Double
  private let log: @Sendable (String) -> Void
  private var runTask: Task<Void, Never>?

  public init(
    dataRoot: URL,
    clock: any NowProviding,
    intervalSeconds: Double,
    evictAfterTranscriptSeconds: Double,
    maxAudioAgeSeconds: Double,
    log: @escaping @Sendable (String) -> Void
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.intervalSeconds = intervalSeconds
    self.evictAfterTranscriptSeconds = evictAfterTranscriptSeconds
    self.maxAudioAgeSeconds = maxAudioAgeSeconds
    self.log = log
  }

  /// Starts the periodic loop: one prompt pass now (recovering anything already
  /// past its deadline from prior runs), then a pass every `intervalSeconds`.
  /// Idempotent — a second call while running is a no-op.
  public func start() {
    guard runTask == nil else { return }
    let interval = intervalSeconds
    runTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweepOnce()
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          return  // cancelled during the wait
        }
      }
    }
  }

  /// Stops the loop. Any pass already in flight runs to completion; no new pass
  /// starts.
  public func stop() {
    runTask?.cancel()
    runTask = nil
  }

  /// One full sweep over every meeting on disk. Internal so tests can drive a
  /// single deterministic pass without the timer.
  func sweepOnce() async {
    let now = clock.now()
    for meeting in MeetingStore.readAll(dataRoot: dataRoot) {
      guard meeting.state == .ended, let ended = meeting.ended else { continue }
      let deadline =
        meeting.transcriptCompleted.map { $0.advanced(by: evictAfterTranscriptSeconds) }
        ?? ended.advanced(by: maxAudioAgeSeconds)
      guard now >= deadline else { continue }

      let sourcesDirectory = DataStoreLayout.meetingDirectory(
        dataRoot: dataRoot, meetingID: meeting.id
      ).appendingPathComponent("sources")
      guard FileManager.default.fileExists(atPath: sourcesDirectory.path) else { continue }
      do {
        try FileManager.default.removeItem(at: sourcesDirectory)
        log("retention: evicted meeting \(meeting.id)'s audio (deadline passed)")
      } catch {
        log("retention: evicting meeting \(meeting.id)'s audio failed: \(error)")
      }
    }
  }
}
