import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Tests the daemon-owned time-cap sweep — the fix for eviction only ever
/// applying to the continuously-capturing mic. The decisive case is a source
/// with **no live actor** (a stopped browser/meeting source, or one left on
/// disk after a restart): the sweep must still expire its aged recordings.
@Suite("EvictionSweeper")
struct EvictionSweeperTests {
  private let startEpoch = 1_000_000.0

  private func makeDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EvictionSweeperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Persists a browser source's `meta.toml` and empty `asr/` chunk files named
  /// for `starts`, returning the source-relative chunk paths.
  @discardableResult
  private func seedSource(
    id: SourceID, timeCapSeconds: Int, starts: [Double], dataRoot: URL
  ) throws -> [String] {
    let descriptor = SourceDescriptor(
      schema: 1, id: id, sourceClass: .browser, label: "",
      nativeSampleRate: 16_000, asrSampleRate: 16_000, storeNative: false,
      channels: 1, codec: "aac", bitrate: 64_000, timeCapSeconds: timeCapSeconds,
      created: Instant(secondsSinceEpoch: startEpoch))
    try SourceMetaStore.write(descriptor, dataRoot: dataRoot)

    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: id)
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
    var files: [String] = []
    for start in starts {
      let filename = FilenameTimestampCodec.string(for: Instant(secondsSinceEpoch: start)) + ".m4a"
      try Data().write(to: asrDirectory.appendingPathComponent(filename))
      files.append("asr/\(filename)")
    }
    return files
  }

  private func remainingASRFiles(id: SourceID, dataRoot: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: id).path)
  }

  @Test("expires a source that has no live actor")
  func expiresActorlessSource() async throws {
    let dataRoot = try makeDataRoot()
    let id: SourceID = "browser:call-abc"
    try seedSource(
      id: id, timeCapSeconds: 100, starts: [startEpoch, startEpoch + 30, startEpoch + 60],
      dataRoot: dataRoot)

    // Clock well past the newest chunk: the whole (stopped) source is behind
    // its cap. No actor exists, so `evictThroughActors` handles nothing.
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch + 100_000))
    let sweeper = EvictionSweeper(
      dataRoot: dataRoot, clock: clock, intervalSeconds: 60, log: { _ in },
      evictThroughActors: { _ in [] })

    await sweeper.sweepOnce()

    #expect(try remainingASRFiles(id: id, dataRoot: dataRoot).isEmpty)
    let events = IndexLog.parse(
      try await IndexAppender(
        fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: id)
      ).readContents()
    ).events
    #expect(events.count == 3)
    #expect(events.allSatisfy { if case .evict = $0 { return true } else { return false } })
  }

  @Test("routes a live source through its actor rather than touching disk")
  func routesLiveSourceThroughActor() async throws {
    let dataRoot = try makeDataRoot()
    let id: SourceID = "browser:live"
    try seedSource(
      id: id, timeCapSeconds: 100, starts: [startEpoch, startEpoch + 30], dataRoot: dataRoot)

    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch + 100_000))
    // Claim the id was handled by a live actor. The sweep must then leave its
    // files alone — the actor (not the disk path) owns that source's index.
    let routed = Mutex<[SourceID]>([])
    let sweeper = EvictionSweeper(
      dataRoot: dataRoot, clock: clock, intervalSeconds: 60, log: { _ in },
      evictThroughActors: { ids in
        routed.withLock { $0.append(contentsOf: ids) }
        return ids
      })

    await sweeper.sweepOnce()

    #expect(routed.withLock { $0 } == [id])
    // Files untouched by the sweep's disk path (the fake actor deleted nothing).
    #expect(try remainingASRFiles(id: id, dataRoot: dataRoot).count == 2)
  }
}
