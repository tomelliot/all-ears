import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Real-temp-directory lifecycle tests for ``SessionRegistry`` -- tier-1 per
/// `docs/engineering-practices.md`. Source-id validation is exercised through
/// the injected `knownSourceIDs` closure (never a real `CaptureActor`, per
/// ``ActorContracts``'s "no `CaptureActor` coupling" decision), and all
/// timestamps come from a ``ManualClock`` so no test touches wall-clock time.
@Suite("SessionRegistry")
struct SessionRegistryTests {
  private static let mic: SourceID = "mic"
  private static let system: SourceID = "system"

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRegistry(
    dataRoot: URL,
    known: Set<SourceID> = [mic, system],
    clock: ManualClock,
    eventSink: EventSink? = nil
  ) -> SessionRegistry {
    SessionRegistry(
      dataRoot: dataRoot,
      knownSourceIDs: { known },
      clock: clock,
      eventSink: eventSink
    )
  }

  // MARK: - open

  @Test(
    "open validates a known source, allocates a <timestamp>_<slug> id, and persists an open descriptor"
  )
  func opensAndPersists() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let descriptor = try await registry.open(
      sources: [Self.mic], slug: "standup", start: nil, vocab: nil)

    #expect(descriptor.id == "2026-07-17T10-30-00Z_standup")
    #expect(descriptor.state == .open)
    #expect(descriptor.end == nil)
    #expect(descriptor.sources == [Self.mic])
    #expect(descriptor.trigger == .manual)

    let onDisk = try SessionStore.read(sessionID: descriptor.id, dataRoot: dataRoot)
    #expect(onDisk == descriptor)
  }

  @Test("open uses an explicit start instant over the clock when given")
  func opensWithExplicitStart() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let explicitStart = Instant(secondsSinceEpoch: 1_784_280_000)

    let descriptor = try await registry.open(
      sources: [Self.mic], slug: "standup", start: explicitStart, vocab: nil)

    #expect(descriptor.start == explicitStart)
    #expect(descriptor.id == "2026-07-17T09-20-00Z_standup")
  }

  @Test("open passes through vocab and trigger")
  func opensWithVocabAndTrigger() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let descriptor = try await registry.open(
      sources: [Self.mic], slug: "standup", start: nil, vocab: "vocab/standup.txt",
      trigger: .appSignal)

    #expect(descriptor.vocab == "vocab/standup.txt")
    #expect(descriptor.trigger == .appSignal)
  }

  @Test("open throws noSources for an empty source list")
  func opensThrowsNoSources() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    await #expect(throws: SessionRegistryError.noSources) {
      try await registry.open(sources: [], slug: "standup", start: nil, vocab: nil)
    }
  }

  @Test("open throws unknownSource for a source the daemon doesn't know")
  func opensThrowsUnknownSource() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let registry = makeRegistry(dataRoot: dataRoot, known: [Self.mic], clock: clock)

    await #expect(throws: SessionRegistryError.unknownSource("bogus")) {
      try await registry.open(
        sources: [Self.mic, "bogus"], slug: "standup", start: nil, vocab: nil)
    }
  }

  // MARK: - close

  @Test("close sets end and state, and re-persists")
  func closesAndPersists() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let opened = try await registry.open(
      sources: [Self.mic], slug: "standup", start: nil, vocab: nil)

    clock.advance(by: 900)
    let closed = try await registry.close(id: opened.id)

    #expect(closed.state == .closed)
    #expect(closed.end == Instant(secondsSinceEpoch: 1_784_285_100))

    let onDisk = try SessionStore.read(sessionID: opened.id, dataRoot: dataRoot)
    #expect(onDisk == closed)
  }

  @Test("close throws sessionNotFound for an unknown id")
  func closeThrowsNotFound() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    await #expect(throws: SessionRegistryError.sessionNotFound("nope")) {
      try await registry.close(id: "nope")
    }
  }

  @Test("close throws sessionAlreadyClosed for an already-closed session")
  func closeThrowsAlreadyClosed() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let opened = try await registry.open(
      sources: [Self.mic], slug: "standup", start: nil, vocab: nil)
    _ = try await registry.close(id: opened.id)

    await #expect(throws: SessionRegistryError.sessionAlreadyClosed(opened.id)) {
      try await registry.close(id: opened.id)
    }
  }

  // MARK: - list

  @Test("list returns open and closed sessions sorted by start")
  func listsSessions() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let second = try await registry.open(
      sources: [Self.mic], slug: "second", start: nil, vocab: nil)
    let first = try await registry.open(
      sources: [Self.mic], slug: "first", start: Instant(secondsSinceEpoch: 1_784_280_000),
      vocab: nil)
    _ = try await registry.close(id: second.id)

    let listed = await registry.list()
    #expect(listed.map(\.id) == [first.id, second.id])
  }

  @Test("list is empty for a fresh registry")
  func listEmptyInitially() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock())

    #expect(await registry.list().isEmpty)
  }

  // MARK: - mark

  @Test("mark with lastSeconds resolves to [now - seconds, now) and writes a closed descriptor")
  func marksLastSeconds() async throws {
    let dataRoot = try makeDataRoot()
    let now = Instant(secondsSinceEpoch: 1_784_284_200)
    let clock = ManualClock(now)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let descriptor = try await registry.mark(
      sources: [Self.mic], slug: "retro", range: .lastSeconds(1800))

    #expect(descriptor.start == now.advanced(by: -1800))
    #expect(descriptor.end == now)
    #expect(descriptor.state == .closed)
    #expect(descriptor.id == "2026-07-17T10-00-00Z_retro")

    let onDisk = try SessionStore.read(sessionID: descriptor.id, dataRoot: dataRoot)
    #expect(onDisk == descriptor)
  }

  @Test("mark with an absolute range uses start/end as given")
  func marksAbsolute() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let start = Instant(secondsSinceEpoch: 1_784_280_000)
    let end = Instant(secondsSinceEpoch: 1_784_281_000)

    let descriptor = try await registry.mark(
      sources: [Self.mic], slug: "retro", range: .absolute(start: start, end: end))

    #expect(descriptor.start == start)
    #expect(descriptor.end == end)
    #expect(descriptor.state == .closed)
  }

  @Test("mark shows up in a subsequent list")
  func markAppearsInList() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let marked = try await registry.mark(
      sources: [Self.mic], slug: "retro", range: .lastSeconds(60))

    let listed = await registry.list()
    #expect(listed.map(\.id) == [marked.id])
  }

  @Test("mark throws noSources for an empty source list")
  func markThrowsNoSources() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    await #expect(throws: SessionRegistryError.noSources) {
      try await registry.mark(sources: [], slug: "retro", range: .lastSeconds(60))
    }
  }

  @Test("mark throws unknownSource for a source the daemon doesn't know")
  func markThrowsUnknownSource() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let registry = makeRegistry(dataRoot: dataRoot, known: [Self.mic], clock: clock)

    await #expect(throws: SessionRegistryError.unknownSource("bogus")) {
      try await registry.mark(sources: ["bogus"], slug: "retro", range: .lastSeconds(60))
    }
  }

  // MARK: - live-feed session events

  @Test("open then close publish matching session lifecycle events")
  func openAndClosePublishEvents() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let recorded = Mutex<[EarsEvent]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    let opened = try await registry.open(
      sources: [Self.mic], slug: "standup", start: nil, vocab: nil)
    _ = try await registry.close(id: opened.id)

    #expect(
      recorded.withLock { $0 } == [
        .session(id: opened.id, state: .open),
        .session(id: opened.id, state: .closed),
      ])
  }

  @Test("mark publishes a single closed event — there was never an open interval")
  func markPublishesClosedEvent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let recorded = Mutex<[EarsEvent]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    let marked = try await registry.mark(
      sources: [Self.mic], slug: "retro", range: .lastSeconds(60))

    #expect(recorded.withLock { $0 } == [.session(id: marked.id, state: .closed)])
  }

  @Test("a failed open publishes nothing")
  func failedOpenPublishesNothing() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let recorded = Mutex<[EarsEvent]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, known: [Self.mic], clock: clock,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    await #expect(throws: SessionRegistryError.unknownSource("bogus")) {
      try await registry.open(sources: ["bogus"], slug: "standup", start: nil, vocab: nil)
    }

    #expect(recorded.withLock { $0 }.isEmpty)
  }
}
