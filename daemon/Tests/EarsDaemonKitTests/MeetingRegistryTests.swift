import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import EarsDaemonKit

/// Real-temp-directory tests for ``MeetingRegistry``, mirroring
/// ``SessionRegistryTests``'s tier: in-memory behavior plus `meeting.toml`
/// persistence, with a ``ManualClock`` so no test touches wall-clock time.
@Suite("MeetingRegistry")
struct MeetingRegistryTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetingRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("resolve mints a UUID for a new (platform, external id) pair and persists meeting.toml")
  func resolvesAndPersists() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = MeetingRegistry(dataRoot: dataRoot, clock: clock)

    let descriptor = try await registry.resolve(platform: "meet", externalID: "AbCdEfGhIjKl")

    #expect(!descriptor.id.isEmpty)
    #expect(descriptor.platform == "meet")
    #expect(descriptor.externalID == "AbCdEfGhIjKl")
    let onDisk = try MeetingStore.read(meetingID: descriptor.id, dataRoot: dataRoot)
    #expect(onDisk == descriptor)
  }

  @Test("resolve is idempotent: the same pair returns the same id, a different pair a new one")
  func resolveIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let registry = MeetingRegistry(dataRoot: dataRoot, clock: ManualClock())

    let first = try await registry.resolve(platform: "meet", externalID: "space-one")
    let again = try await registry.resolve(platform: "meet", externalID: "space-one")
    let other = try await registry.resolve(platform: "meet", externalID: "space-two")
    let otherPlatform = try await registry.resolve(platform: "zoom", externalID: "space-one")

    #expect(again == first)
    #expect(other.id != first.id)
    #expect(otherPlatform.id != first.id)
  }

  @Test("resolve survives a registry restart — the persisted lookup wins over a fresh UUID")
  func resolveSurvivesRestart() async throws {
    let dataRoot = try makeDataRoot()
    let first = try await MeetingRegistry(dataRoot: dataRoot, clock: ManualClock())
      .resolve(platform: "meet", externalID: "space-one")

    // A brand-new registry over the same data root — the daemon restarting.
    let rejoined = try await MeetingRegistry(dataRoot: dataRoot, clock: ManualClock())
      .resolve(platform: "meet", externalID: "space-one")

    #expect(rejoined.id == first.id)
  }

  @Test("resolve rejects an empty platform or external id")
  func resolveValidates() async throws {
    let dataRoot = try makeDataRoot()
    let registry = MeetingRegistry(dataRoot: dataRoot, clock: ManualClock())

    await #expect(throws: MeetingRegistryError.emptyPlatform) {
      try await registry.resolve(platform: "", externalID: "space-one")
    }
    await #expect(throws: MeetingRegistryError.emptyExternalID) {
      try await registry.resolve(platform: "meet", externalID: "")
    }
  }

  @Test("a corrupt meeting.toml is skipped on load, not fatal")
  func corruptDescriptorSkipped() async throws {
    let dataRoot = try makeDataRoot()
    let corruptDirectory = DataStoreLayout.meetingDirectory(
      dataRoot: dataRoot, meetingID: "corrupt")
    try FileManager.default.createDirectory(
      at: corruptDirectory, withIntermediateDirectories: true)
    try "not = valid meeting toml".write(
      to: corruptDirectory.appendingPathComponent("meeting.toml"), atomically: true,
      encoding: .utf8)

    let registry = MeetingRegistry(dataRoot: dataRoot, clock: ManualClock())
    let descriptor = try await registry.resolve(platform: "meet", externalID: "space-one")
    #expect(descriptor.platform == "meet")
  }
}
