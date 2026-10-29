import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory tests for ``SessionStore/Cache``: the daemon's guard
/// against re-parsing (and so re-leaking, via TOMLKit) every unchanged
/// `session.toml` on each retention sweep.
@Suite("SessionStore.Cache")
struct SessionStoreCacheTests {
  private let base = Instant(secondsSinceEpoch: 1_000_000)

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionStoreCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func session(id: String, title: String = "call") -> Session {
    Session(
      id: id,
      title: title,
      state: .ended,
      started: base,
      ended: base.advanced(by: 60),
      intervals: [SessionInterval(start: base, end: base.advanced(by: 60))],
      sources: ["mic"])
  }

  @Test("an unchanged session.toml is parsed once across repeated scans")
  func unchangedFileIsNotReparsed() throws {
    let dataRoot = try makeDataRoot()
    try SessionStore.write(session(id: "a"), dataRoot: dataRoot)
    try SessionStore.write(session(id: "b"), dataRoot: dataRoot)
    let cache = SessionStore.Cache()

    let first = SessionStore.readAll(dataRoot: dataRoot, cache: cache)
    let second = SessionStore.readAll(dataRoot: dataRoot, cache: cache)

    #expect(first.map(\.id) == ["a", "b"])
    #expect(second == first)
    #expect(cache.parseCount == 2)
  }

  @Test("a session.toml changed by another writer is read again")
  func externallyChangedFileIsReread() throws {
    let dataRoot = try makeDataRoot()
    try SessionStore.write(session(id: "a", title: "before"), dataRoot: dataRoot)
    let cache = SessionStore.Cache()
    #expect(SessionStore.readAll(dataRoot: dataRoot, cache: cache).map(\.title) == ["before"])

    // No cache passed: another process (or another writer) changed the file.
    try SessionStore.write(session(id: "a", title: "after!"), dataRoot: dataRoot)

    #expect(SessionStore.readAll(dataRoot: dataRoot, cache: cache).map(\.title) == ["after!"])
    #expect(cache.parseCount == 2)
  }

  @Test("a write through the cache is seen fresh on the next read")
  func writeThroughCacheInvalidates() throws {
    let dataRoot = try makeDataRoot()
    let cache = SessionStore.Cache()
    try SessionStore.write(session(id: "a", title: "one"), dataRoot: dataRoot, cache: cache)
    #expect(try SessionStore.read(sessionID: "a", dataRoot: dataRoot, cache: cache).title == "one")

    // Same size, likely the same modification date: the write's invalidation
    // is what tells the cache the file changed.
    try SessionStore.write(session(id: "a", title: "two"), dataRoot: dataRoot, cache: cache)

    #expect(try SessionStore.read(sessionID: "a", dataRoot: dataRoot, cache: cache).title == "two")
    #expect(cache.parseCount == 2)
  }

  @Test("a deleted session drops out of the scan and the cache")
  func deletedSessionDropsOut() throws {
    let dataRoot = try makeDataRoot()
    try SessionStore.write(session(id: "a"), dataRoot: dataRoot)
    try SessionStore.write(session(id: "b"), dataRoot: dataRoot)
    let cache = SessionStore.Cache()
    #expect(SessionStore.readAll(dataRoot: dataRoot, cache: cache).count == 2)

    try FileManager.default.removeItem(
      at: DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: "a"))

    #expect(SessionStore.readAll(dataRoot: dataRoot, cache: cache).map(\.id) == ["b"])
    #expect(throws: DataStoreError.sessionNotFound("a")) {
      try SessionStore.read(sessionID: "a", dataRoot: dataRoot, cache: cache)
    }
    #expect(cache.parseCount == 2)
  }

  @Test("an unparseable session.toml is reported to onSkip on every scan, parsed once")
  func corruptFileStillSkippedEachScan() throws {
    let dataRoot = try makeDataRoot()
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: "bad")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema = [not toml".utf8).write(to: url)
    let cache = SessionStore.Cache()

    var skipped: [String] = []
    for _ in 0..<2 {
      let sessions = SessionStore.readAll(
        dataRoot: dataRoot, cache: cache, onSkip: { id, _ in skipped.append(id) })
      #expect(sessions.isEmpty)
    }

    #expect(skipped == ["bad", "bad"])
    #expect(cache.parseCount == 1)
  }
}
