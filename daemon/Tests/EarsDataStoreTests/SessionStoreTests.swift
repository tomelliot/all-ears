import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory round-trip tests for ``SessionStore`` -- tier-1 per
/// `docs/engineering-practices.md`. The TOML content mapping itself
/// (``SessionDescriptorTOML``) is already covered in `EarsConfigTests`;
/// these tests cover the file I/O this type adds: path layout, directory
/// creation, and the not-found error.
@Suite("SessionStore")
struct SessionStoreTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static let referenceDescriptor = SessionDescriptor(
    schema: 1,
    id: "2026-07-17T10-30-00Z_standup",
    slug: "standup",
    sources: ["mic", "app:us.zoom.xos"],
    start: Instant(secondsSinceEpoch: 1_784_284_200),
    end: Instant(secondsSinceEpoch: 1_784_286_120),
    state: .closed,
    trigger: .appSignal,
    triggerDetail: "us.zoom.xos",
    vocab: "vocab/2026-07-17T10-30-00Z_standup.txt"
  )

  @Test("writes session.toml at the documented path, creating the session directory")
  func writesAtDocumentedPath() throws {
    let dataRoot = try makeDataRoot()
    try SessionStore.write(Self.referenceDescriptor, dataRoot: dataRoot)

    let expectedPath = dataRoot.appendingPathComponent(
      "sessions/2026-07-17T10-30-00Z_standup/session.toml")
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))
  }

  @Test("round-trips a closed session through a real file")
  func roundTripsClosedSession() throws {
    let dataRoot = try makeDataRoot()
    try SessionStore.write(Self.referenceDescriptor, dataRoot: dataRoot)

    let readBack = try SessionStore.read(sessionID: Self.referenceDescriptor.id, dataRoot: dataRoot)
    #expect(readBack == Self.referenceDescriptor)
  }

  @Test("round-trips an open session (nil end) through a real file")
  func roundTripsOpenSession() throws {
    let dataRoot = try makeDataRoot()
    var open = Self.referenceDescriptor
    open.end = nil
    open.state = .open
    try SessionStore.write(open, dataRoot: dataRoot)

    let readBack = try SessionStore.read(sessionID: open.id, dataRoot: dataRoot)
    #expect(readBack == open)
    #expect(readBack.end == nil)
  }

  @Test("reading a session with no session.toml throws sessionNotFound")
  func missingFileThrows() throws {
    let dataRoot = try makeDataRoot()
    #expect(throws: DataStoreError.sessionNotFound("missing")) {
      try SessionStore.read(sessionID: "missing", dataRoot: dataRoot)
    }
  }
}
