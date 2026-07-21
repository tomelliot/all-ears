import EarsCore
import EarsDataStore
import Foundation

/// The daemon's time-cap enforcer: a single, timer-driven pass that expires
/// recordings older than each source's `time_cap_seconds` (default 7200 = 2 h)
/// across **every** source, owned by the daemon rather than by any one source's
/// capture path.
///
/// ## Why this exists
///
/// The time cap is a wall-clock bound, but eviction used to fire only when a new
/// chunk rolled over (or once at a source's `start()`). The mic captures
/// continuously, so its rollovers kept it pruned — and it looked like expiry
/// worked. Every other source is episodic: a browser/meeting source captures
/// for a call and then stops, rolls no more chunks, and its recordings sat on
/// disk past the cap forever (never re-instantiated as an actor after a daemon
/// restart, either). So in practice only the mic was ever expired.
///
/// This sweeper decouples enforcement from capture entirely. Each tick it
/// enumerates the sources present on disk (``SourceDirectoryScan``) — not the
/// live actor set — so it reaches stopped and actor-less sources, and evicts:
///
/// - **through the live `CaptureActor`** (``CaptureActor/evictNow()``) for
///   sources that have one, so that actor's shared ``IndexAppender`` stays the
///   single writer to its `index.jsonl` and its `status` bounds stay fresh;
/// - **straight from disk** (``EvictionExecutor/evictFromDisk``, deciding from
///   filenames via ``DiskChunkScan``) for sources with no live actor, where no
///   other writer exists to race.
public actor EvictionSweeper {
  private let dataRoot: URL
  private let clock: any NowProviding
  private let intervalSeconds: Double
  private let log: @Sendable (String) -> Void
  /// Asks the daemon to evict every id that has a live `CaptureActor` through
  /// that actor, returning the ids it handled — so the sweep disk-evicts only
  /// the rest. Injected (not a direct actor-map reference) so the daemon keeps
  /// sole ownership of its `captureActors`.
  private let evictThroughActors: @Sendable (Set<SourceID>) async -> Set<SourceID>
  private var runTask: Task<Void, Never>?

  public init(
    dataRoot: URL,
    clock: any NowProviding,
    intervalSeconds: Double,
    log: @escaping @Sendable (String) -> Void,
    evictThroughActors: @escaping @Sendable (Set<SourceID>) async -> Set<SourceID>
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.intervalSeconds = intervalSeconds
    self.log = log
    self.evictThroughActors = evictThroughActors
  }

  /// Starts the periodic loop: one prompt pass now (recovering anything already
  /// past the cap from prior runs or stopped sources), then a pass every
  /// `intervalSeconds`. Idempotent — a second call while running is a no-op.
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

  /// One full sweep over every on-disk source. Internal so tests can drive a
  /// single deterministic pass without the timer.
  func sweepOnce() async {
    let sources = SourceDirectoryScan.sources(dataRoot: dataRoot)
    guard !sources.isEmpty else { return }
    let now = clock.now()

    let handled = await evictThroughActors(Set(sources.map { $0.descriptor.id }))

    for (descriptor, directory) in sources where !handled.contains(descriptor.id) {
      // No live actor for this source, so a fresh IndexAppender is the only
      // writer to its index — safe. (A source gaining an actor between the
      // routing snapshot above and here is a single-tick window; the resulting
      // double-write is idempotent: deleteChunkFiles guards file existence and a
      // duplicate `evict` event is inert to every index reader.)
      let indexAppender = IndexAppender(
        fileURL: DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: descriptor.id))
      do {
        try await EvictionExecutor.evictFromDisk(
          sourceDirectory: directory,
          storeNative: descriptor.storeNative,
          now: now,
          timeCapSeconds: Double(descriptor.timeCapSeconds),
          indexAppender: indexAppender)
      } catch {
        log("eviction sweep: source '\(descriptor.id.rawValue)' failed: \(error)")
      }
    }
  }
}
