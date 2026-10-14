import EarsCore
import EarsDataStore
import Foundation

/// The daemon's retention enforcer: a single, timer-driven pass that deletes
/// each **ended session's** audio (`sessions/<id>/sources/`) once its
/// retention deadline passes, per `[earsd.retention]`:
///
/// - transcript completed successfully → deleted at
///   `transcript_completed + evict_after_transcript_seconds`;
/// - transcript never completed → retained (so a failed run can be retried)
///   until `ended + max_audio_age_seconds`, then deleted regardless.
///
/// The first deadline always wins arithmetically when both exist
/// (`completed + evict_after < ended + max_age` for the shipped defaults), so
/// no explicit whichever-first logic is needed. `session.toml` and
/// `events.jsonl` are never deleted — the session's record outlives its
/// audio. Live (non-ended) sessions are never touched, no matter how old.
///
/// Retention is a per-session directory delete because audio is
/// session-scoped: everything a session recorded lives under its own
/// `sources/` tree, so eviction needs no chunk-level bookkeeping, no index
/// rewrite, and no coordination with a live `CaptureActor` (an ended
/// session's actors are already torn down).
public actor EvictionSweeper {
  private let dataRoot: URL
  private let clock: any NowProviding
  private let intervalSeconds: Double
  private let evictAfterTranscriptSeconds: Double
  private let maxAudioAgeSeconds: Double
  private let log: @Sendable (String) -> Void
  /// Keeps an unchanged `session.toml` from being parsed again every pass —
  /// see ``SessionStore/Cache`` for the leak this avoids.
  private let descriptorCache: SessionStore.Cache
  private var runTask: Task<Void, Never>?

  public init(
    dataRoot: URL,
    clock: any NowProviding,
    intervalSeconds: Double,
    evictAfterTranscriptSeconds: Double,
    maxAudioAgeSeconds: Double,
    descriptorCache: SessionStore.Cache = SessionStore.Cache(),
    log: @escaping @Sendable (String) -> Void
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.intervalSeconds = intervalSeconds
    self.evictAfterTranscriptSeconds = evictAfterTranscriptSeconds
    self.maxAudioAgeSeconds = maxAudioAgeSeconds
    self.descriptorCache = descriptorCache
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

  /// One full sweep over every session on disk. Internal so tests can drive a
  /// single deterministic pass without the timer.
  func sweepOnce() async {
    let now = clock.now()
    for session in SessionStore.readAll(dataRoot: dataRoot, cache: descriptorCache) {
      guard session.state == .ended, let ended = session.ended else { continue }
      let deadline =
        session.transcriptCompleted.map { $0.advanced(by: evictAfterTranscriptSeconds) }
        ?? ended.advanced(by: maxAudioAgeSeconds)
      guard now >= deadline else { continue }

      let sourcesDirectory = DataStoreLayout.sessionDirectory(
        dataRoot: dataRoot, sessionID: session.id
      ).appendingPathComponent("sources")
      guard FileManager.default.fileExists(atPath: sourcesDirectory.path) else { continue }
      do {
        try FileManager.default.removeItem(at: sourcesDirectory)
        log("retention: evicted session \(session.id)'s audio (deadline passed)")
      } catch {
        log("retention: evicting session \(session.id)'s audio failed: \(error)")
      }
    }
  }
}
