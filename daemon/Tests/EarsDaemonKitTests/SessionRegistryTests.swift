import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Real-temp-directory tests for ``SessionRegistry``, the v2 session
/// lifecycle owner: idempotent `session.start`, pause/resume interval
/// bookkeeping, restart recovery, the orphan grace timer, rename
/// compare-and-set, and the ended hook fired at `session.end` — with
/// a ``ManualClock`` and an injected sleep so no test touches real time.
@Suite("SessionRegistry")
struct SessionRegistryTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRegistry(
    dataRoot: URL,
    clock: ManualClock,
    bus: EventBus? = nil,
    graceSeconds: Double = 120,
    rejoinHoldSeconds: Double = 0,
    sleep: (@Sendable (Double) async -> Void)? = nil,
    onEnded: SessionRegistry.EndedHook? = nil,
    localBrowserSources: [SourceID] = [],
    knownSourceIDs: @escaping @Sendable () async -> Set<SourceID> = { [] },
    log: (@Sendable (String) -> Void)? = nil
  ) -> SessionRegistry {
    let ids = Mutex(0)
    return SessionRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "session-\(next)"
        }
      },
      bus: bus,
      graceSeconds: graceSeconds,
      rejoinHoldSeconds: rejoinHoldSeconds,
      sleep: sleep ?? { _ in },
      onEnded: onEnded,
      localBrowserSources: localBrowserSources,
      knownSourceIDs: knownSourceIDs,
      log: log ?? { _ in })
  }

  // MARK: - start

  @Test("start persists an active session with one open interval")
  func startPersists() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))

    #expect(session.state == .active)
    #expect(session.intervals == [SessionInterval(start: base)])
    #expect(session.trigger == .browserExtension)
    let onDisk = try SessionStore.read(sessionID: session.id, dataRoot: dataRoot)
    #expect(onDisk.state == .active)
    #expect(onDisk.intervals.first?.end == nil)
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    #expect(timeline.map(\.event) == ["started", "interval_opened"])
  }

  @Test("a browser session folds in the configured local sources it can capture")
  func startInjectsLocalBrowserSources() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      localBrowserSources: ["mic"],
      knownSourceIDs: { ["mic", "system"] })

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))

    // Declared sources keep their order; the capturable local source appends.
    #expect(session.sources == ["browser:meet:jane", "mic"])
    let onDisk = try SessionStore.read(sessionID: session.id, dataRoot: dataRoot)
    #expect(onDisk.sources == ["browser:meet:jane", "mic"])
  }

  @Test("a local source the daemon isn't capturing is not attached")
  func startSkipsUnknownLocalSource() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      localBrowserSources: ["mic"],
      knownSourceIDs: { [] })  // mic isn't being captured

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", trigger: .browserExtension))

    #expect(session.sources == [])
  }

  @Test("local sources are folded into browser sessions only, not manual ones")
  func startInjectsForBrowserTriggerOnly() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      localBrowserSources: ["mic"],
      knownSourceIDs: { ["mic"] })

    let manual = try await registry.start(
      SessionStartParams(title: "standup", sources: ["app:zoom"]))

    // A manual/CLI session names its own sources; mic is not force-added.
    #expect(manual.trigger == .manual)
    #expect(manual.sources == ["app:zoom"])
  }

  @Test("start is idempotent on identity: re-declaring returns the same live session")
  func startIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let first = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc"))
    let second = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", title: "ignored on re-declare"))
    let other = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "different"))

    #expect(second.id == first.id)
    #expect(second.title == first.title)
    #expect(other.id != first.id)
  }

  @Test("re-declaring after end starts a fresh session under the same identity")
  func rejoinAfterEnd() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let first = try await registry.start(SessionStartParams(platform: "meet", externalID: "abc"))
    _ = try await registry.end(id: first.id)
    let second = try await registry.start(SessionStartParams(platform: "meet", externalID: "abc"))

    #expect(second.id != first.id)
    #expect(second.state == .active)
  }

  @Test("a manual session (no identity) is first-class")
  func manualSession() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let session = try await registry.start(
      SessionStartParams(title: "standup", sources: ["mic"]))

    #expect(session.identity == nil)
    #expect(session.title == "standup")
    #expect(session.trigger == .manual)
    #expect(!session.isBrowserSession)
  }

  // MARK: - single active session invariant (#27)

  @Test("starting a session supersedes any live session (reason superseded)")
  func startSupersedesLiveSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    // A stale session left live (the 2026-07-23 chain: one real, one stale).
    let stale = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "stale", sources: ["browser:meet:a"],
        trigger: .browserExtension))
    clock.advance(by: 300)
    let real = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "real", sources: ["browser:meet:b"],
        trigger: .browserExtension))

    #expect(real.id != stale.id)
    #expect(real.state == .active)

    let staleFinal = try await registry.get(id: stale.id)
    #expect(staleFinal.state == .ended)
    let staleTimeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: stale.id)
    #expect(staleTimeline.last?.event == "ended")
    #expect(staleTimeline.last?.reason == "superseded")

    // Exactly one live session remains — the invariant holds.
    let live = await registry.list().filter { $0.state != .ended }
    #expect(live.map(\.id) == [real.id])
  }

  @Test("a duplicate start for the same identity does not supersede or restart the session")
  func duplicateStartSameIdentityIsIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let first = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    clock.advance(by: 5)
    let again = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))

    #expect(again.id == first.id)
    #expect(again.state == .active)
    // Not restarted: still a single open interval, and never ended.
    #expect(again.intervals.count == 1)
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: first.id)
    #expect(!timeline.map(\.event).contains("ended"))
  }

  @Test("supersede stops the old session's capture before it starts the new session's")
  func supersedeReleasesCaptureBeforeStartingNew() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let calls = Mutex<[String]>([])
    let ids = Mutex(0)
    let registry = SessionRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "session-\(next)"
        }
      },
      startCapture: { id, _ in calls.withLock { $0.append("start:\(id)") } },
      stopCapture: { id, _ in calls.withLock { $0.append("stop:\(id)") } })

    let a = try await registry.start(SessionStartParams(title: "a", sources: ["mic"]))
    let b = try await registry.start(SessionStartParams(title: "b", sources: ["mic"]))

    // The superseded session releases the shared mic (stop) before the
    // successor claims it (start) — so the new session rebuilds against its own
    // directory, never the old one's.
    #expect(calls.withLock { $0 } == ["start:\(a.id)", "stop:\(a.id)", "start:\(b.id)"])
  }

  @Test("boot resumes only the latest-started session; older active records are orphaned")
  func bootSweepResumesOneOrphansRest() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base.advanced(by: 10_000))

    // Two sessions left `active` on disk by a previous daemon instance.
    let stale = Session(
      id: "stale", identity: SessionIdentity(platform: "meet", externalID: "old"),
      title: "old", state: .active, started: base,
      intervals: [SessionInterval(start: base)], sources: ["browser:meet:a"],
      trigger: .browserExtension)
    let recent = Session(
      id: "recent", identity: SessionIdentity(platform: "meet", externalID: "new"),
      title: "new", state: .active, started: base.advanced(by: 500),
      intervals: [SessionInterval(start: base.advanced(by: 500))], sources: ["browser:meet:b"],
      trigger: .browserExtension)
    try SessionStore.write(stale, dataRoot: dataRoot)
    try SessionStore.write(recent, dataRoot: dataRoot)

    let startCaptures = Mutex<[String]>([])
    let ids = Mutex(0)
    let registry = SessionRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "m-\(next)"
        }
      },
      startCapture: { id, _ in startCaptures.withLock { $0.append(id) } })
    await registry.loadFromDisk()

    #expect(try await registry.get(id: "recent").state == .active)
    #expect(try await registry.get(id: "stale").state == .ended)
    let staleTimeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: "stale")
    #expect(staleTimeline.last?.reason == "orphaned")

    // Only the survivor resumed capture; the orphan ran its on_end pipeline.
    #expect(startCaptures.withLock { $0 } == ["recent"])
    let live = await registry.list().filter { $0.state != .ended }
    #expect(live.map(\.id) == ["recent"])
  }

  // MARK: - pause / resume (intervals are marks, never capture control)

  @Test("pause closes the open interval; resume opens a new one")
  func pauseResumeIntervals() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let started = try await registry.start(SessionStartParams(title: "standup"))

    clock.advance(by: 750)
    let paused = try await registry.pause(id: started.id)
    #expect(paused.state == .paused)
    #expect(paused.intervals == [SessionInterval(start: base, end: base.advanced(by: 750))])

    clock.advance(by: 455)
    let resumed = try await registry.resume(id: started.id)
    #expect(resumed.state == .active)
    #expect(resumed.intervals.count == 2)
    #expect(resumed.intervals[1] == SessionInterval(start: base.advanced(by: 1205)))

    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: started.id)
    #expect(
      timeline.map(\.event)
        == ["started", "interval_opened", "interval_closed", "interval_opened"])
  }

  @Test("pause when already paused (and resume when active) are converging no-ops")
  func pauseResumeIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))
    let started = try await registry.start(SessionStartParams(title: "standup"))

    let once = try await registry.resume(id: started.id)  // already active
    #expect(once.intervals.count == 1)
    _ = try await registry.pause(id: started.id)
    let twice = try await registry.pause(id: started.id)  // already paused
    #expect(twice.state == .paused)
    #expect(twice.intervals.count == 1)
  }

  @Test("lifecycle verbs on an ended session fail with the ended error")
  func endedSessionRejectsLifecycle() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))
    let session = try await registry.start(SessionStartParams(title: "standup"))
    _ = try await registry.end(id: session.id)

    await #expect(throws: SessionRegistryError.ended(session.id)) {
      try await registry.pause(id: session.id)
    }
    await #expect(throws: SessionRegistryError.notFound("nope")) {
      try await registry.resume(id: "nope")
    }
  }

  // MARK: - end

  @Test(
    "end closes every interval, persists the final state, and fires the ended hook with the final session"
  )
  func endFiresHookWithFinalSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let endedSessions = Mutex<[Session]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      onEnded: { session in
        endedSessions.withLock { $0.append(session) }
      })

    let started = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["mic", "browser:meet:jane"],
        trigger: .browserExtension))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: started.id, id: "spaces/x/devices/y", displayName: "Jane Doe",
        source: "browser:meet:jane"))
    clock.advance(by: 600)
    _ = try await registry.pause(id: started.id)
    clock.advance(by: 120)
    _ = try await registry.resume(id: started.id)
    clock.advance(by: 300)
    let ended = try await registry.end(id: started.id)

    #expect(ended.state == .ended)
    #expect(ended.ended == base.advanced(by: 1020))
    #expect(ended.intervals.allSatisfy { $0.end != nil })

    // The hook receives only the final session — the roster (attendee
    // `source` → `display_name`) travels on the session itself; speaker
    // names are derived from it at transcribe time.
    let hooks = endedSessions.withLock { $0 }
    #expect(hooks.count == 1)
    #expect(hooks[0].state == .ended)
    #expect(hooks[0].attendees.first?.displayName == "Jane Doe")
    #expect(hooks[0].attendees.first?.source == "browser:meet:jane")

    // The final state is persisted as sessions/<id>/session.toml (schema 3).
    let sessionTOML =
      dataRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent(started.id)
      .appendingPathComponent("session.toml")
    #expect(FileManager.default.fileExists(atPath: sessionTOML.path))

    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: started.id)
    #expect(timeline.last?.event == "ended")
    #expect(timeline.last?.reason == "client")
  }

  @Test("end is idempotent: a second end returns the final state without re-firing the hook")
  func endIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let hookCount = Mutex(0)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base),
      onEnded: { _ in hookCount.withLock { $0 += 1 } })
    let session = try await registry.start(SessionStartParams(title: "standup"))

    _ = try await registry.end(id: session.id)
    let again = try await registry.end(id: session.id)

    #expect(again.state == .ended)
    #expect(hookCount.withLock { $0 } == 1)
  }

  // MARK: - session-scoped capture

  @Test("capture starts on session start and stops on session end")
  func sessionScopesCapture() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let startCalls = Mutex<[[SourceID]]>([])
    let stopCalls = Mutex<[[SourceID]]>([])
    let ids = Mutex(0)
    let registry = SessionRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "session-\(next)"
        }
      },
      startCapture: { _, sources in startCalls.withLock { $0.append(sources) } },
      stopCapture: { _, sources in stopCalls.withLock { $0.append(sources) } })

    let session = try await registry.start(
      SessionStartParams(title: "standup", sources: ["mic"]))
    #expect(startCalls.withLock { $0 } == [["mic"]])
    #expect(stopCalls.withLock { $0 }.isEmpty)

    _ = try await registry.end(id: session.id)
    #expect(stopCalls.withLock { $0 } == [["mic"]])
  }

  @Test("markTranscriptCompleted records the completion instant durably")
  func marksTranscriptCompleted() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let session = try await registry.start(SessionStartParams(title: "standup"))
    _ = try await registry.end(id: session.id)
    #expect(try await registry.get(id: session.id).transcriptCompleted == nil)

    await registry.markTranscriptCompleted(id: session.id, at: base.advanced(by: 300))

    #expect(try await registry.get(id: session.id).transcriptCompleted == base.advanced(by: 300))
    // Durable: read straight back off disk.
    let reloaded = try SessionStore.read(sessionID: session.id, dataRoot: dataRoot)
    #expect(reloaded.transcriptCompleted == base.advanced(by: 300))
  }

  // MARK: - rename / attendee

  @Test("rename is a compare-and-set under if_rev")
  func renameConflict() async throws {
    let dataRoot = try makeDataRoot()
    let bus = EventBus()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base), bus: bus)
    let session = try await registry.start(SessionStartParams(title: "standup"))

    let renamed = try await registry.rename(
      id: session.id, title: "Weekly sync", ifRev: session.rev)
    #expect(renamed.title == "Weekly sync")
    #expect(renamed.rev > session.rev)

    await #expect(throws: SessionRegistryError.self) {
      _ = try await registry.rename(id: session.id, title: "stale", ifRev: session.rev)
    }
  }

  @Test("attendee upserts merge fields and join the session's source list")
  func attendeeUpsert() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let session = try await registry.start(SessionStartParams(platform: "meet", externalID: "a"))

    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "p1", displayName: "Jane Doe", origin: .platform))
    clock.advance(by: 60)
    let linked = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "p1", source: "browser:meet:jane"))

    #expect(linked.attendees.count == 1)
    let attendee = linked.attendees[0]
    #expect(attendee.displayName == "Jane Doe")  // earlier field kept
    #expect(attendee.source == "browser:meet:jane")
    // An upsert that omits `origin` leaves the declared provenance alone.
    #expect(attendee.origin == .platform)
    #expect(attendee.joined == base)  // stamped at first upsert
    #expect(linked.sources.contains("browser:meet:jane"))

    clock.advance(by: 60)
    let left = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "p1", left: clock.now()))
    #expect(left.attendees[0].left == base.advanced(by: 120))
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    #expect(timeline.map(\.event).contains("attendee_joined"))
    #expect(timeline.last?.event == "attendee_left")
  }

  @Test("every attendee upsert logs what it received and what it stored (issue #23)")
  func attendeeUpsertLogsProvenance() async throws {
    let dataRoot = try makeDataRoot()
    let logs = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base),
      log: { line in logs.withLock { $0.append(line) } })
    let session = try await registry.start(SessionStartParams(platform: "meet", externalID: "a"))

    // A name-only upsert: "sent" this time.
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "spaces/s/devices/445", displayName: "Tom Elliot"))
    // A source-only upsert for a different attendee: name "never sent".
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "speaker-1", source: "browser:meet:speaker-1"))

    let upsertLogs = logs.withLock { $0 }.filter { $0.hasPrefix("session.attendee upsert:") }
    #expect(upsertLogs.count == 2)
    // The name-bearing upsert records the received and stored name.
    #expect(
      upsertLogs.contains {
        $0.contains("attendee=spaces/s/devices/445") && $0.contains("new=true")
          && $0.contains("recv_display_name=\"Tom Elliot\"")
          && $0.contains("stored_display_name=\"Tom Elliot\"")
      })
    // The source-only upsert shows the name was never sent (recv/stored both `-`),
    // distinguishing "never sent" from "sent but not merged".
    #expect(
      upsertLogs.contains {
        $0.contains("attendee=speaker-1") && $0.contains("recv_display_name=-")
          && $0.contains("stored_display_name=-")
          && $0.contains("recv_source=\"browser:meet:speaker-1\"")
      })
  }

  @Test("session end logs a roster summary naming unresolved attendees (issue #23)")
  func endLogsRosterSummary() async throws {
    let dataRoot = try makeDataRoot()
    let logs = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base),
      log: { line in logs.withLock { $0.append(line) } })
    let session = try await registry.start(SessionStartParams(platform: "meet", externalID: "a"))

    // Fully resolved: name + source.
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "spaces/s/devices/445", displayName: "Tom Elliot",
        source: "browser:meet:spaces-s-devices-445"))
    // Named but never tied to a track (no source).
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "spaces/s/devices/446", displayName: "Tom E"))
    // A captured track that never resolved a name (source but no name).
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "speaker-1", source: "browser:meet:speaker-1"))

    _ = try await registry.end(id: session.id)

    let summary = try #require(
      logs.withLock { $0 }.first { $0.hasPrefix("session.end roster summary:") })
    #expect(summary.contains("attendees=3"))
    #expect(summary.contains("with_name=2"))
    #expect(summary.contains("with_source=2"))
    // Both partially-resolved attendees are named explicitly with what's missing.
    #expect(summary.contains("spaces/s/devices/446(name=yes,source=no)"))
    #expect(summary.contains("speaker-1(name=no,source=yes)"))
    // The fully-resolved attendee is not listed as unresolved.
    #expect(!summary.contains("spaces/s/devices/445("))
  }

  // MARK: - restart recovery

  @Test("an active session with an open interval survives a daemon restart")
  func restartRecovery() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let first = makeRegistry(dataRoot: dataRoot, clock: clock)
    let started = try await first.start(
      SessionStartParams(platform: "meet", externalID: "abc"))

    // A second registry over the same data root — a fresh daemon boot.
    let second = makeRegistry(dataRoot: dataRoot, clock: clock)
    await second.loadFromDisk()

    let reloaded = try await second.get(id: started.id)
    #expect(reloaded.state == .active)
    #expect(reloaded.intervals.first?.end == nil)
    // Idempotency index reloads too: re-declaring converges on the same id.
    let redeclared = try await second.start(
      SessionStartParams(platform: "meet", externalID: "abc"))
    #expect(redeclared.id == started.id)
  }

  @Test("boot repairs an unparseable session.toml so its audio re-enters retention")
  func bootRepairsCorruptDescriptor() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let clock = ManualClock(base)

    // A session directory left behind with recorded audio and a descriptor
    // that no longer parses (torn write, disk fault, hand edit).
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: "corrupt-1")
    let audioDirectory = sessionRoot.appendingPathComponent("sources/mic/asr")
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: audioDirectory.appendingPathComponent("chunk.m4a"))
    try Data("schema = [not toml".utf8).write(
      to: sessionRoot.appendingPathComponent("session.toml"))

    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    await registry.loadFromDisk()

    // The unreadable original is preserved for diagnosis…
    #expect(
      FileManager.default.fileExists(
        atPath: sessionRoot.appendingPathComponent("session.toml.corrupt").path))
    // …and a minimal ended record takes its place, stamped with the boot
    // instant and a warning naming the repair.
    let repaired = try SessionStore.read(sessionID: "corrupt-1", dataRoot: dataRoot)
    #expect(repaired.state == .ended)
    #expect(repaired.ended == base)
    #expect(repaired.warnings.contains { $0.contains("session.toml.corrupt") })

    // Which is exactly what puts the audio back inside retention: a sweep past
    // the max audio age now evicts it.
    let sweeper = EvictionSweeper(
      dataRoot: dataRoot,
      clock: ManualClock(base.advanced(by: 2_000)),
      intervalSeconds: 60,
      evictAfterTranscriptSeconds: 100,
      maxAudioAgeSeconds: 1_000,
      log: { _ in })
    await sweeper.sweepOnce()
    #expect(
      !FileManager.default.fileExists(
        atPath: sessionRoot.appendingPathComponent("sources").path))
  }

  // MARK: - rejoin hold

  /// The 2026-11-26 Meet call: the extension ended the meeting and declared
  /// it again three seconds later, which made two sessions writing the same
  /// transcript and note paths.
  @Test("a rejoin of the same meeting within the hold continues the session")
  func rejoinWithinHoldContinuesSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let ended = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, rejoinHoldSeconds: 60,
      sleep: { seconds in await gate.wait(seconds) },
      onEnded: { session in ended.withLock { $0.append(session.id) } })
    let params = SessionStartParams(
      platform: "meet", externalID: "efY", sources: ["browser:meet:t1"],
      trigger: .browserExtension)

    let first = try await registry.start(params)
    let held = try await registry.end(id: first.id)
    #expect(held.state == .paused)
    #expect(ended.withLock { $0 }.isEmpty)
    // A repeated end during the hold does not cut it short.
    #expect(try await registry.end(id: first.id).state == .paused)

    clock.advance(by: 3)
    let rejoined = try await registry.start(params)
    #expect(rejoined.id == first.id)
    #expect(rejoined.state == .active)
    #expect(rejoined.intervals.count == 2)

    // The hold's timer firing after the rejoin is a no-op.
    await gate.releaseAll()
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(try await registry.get(id: first.id).state == .active)
    #expect(ended.withLock { $0 }.isEmpty)
  }

  @Test("with no rejoin, a held session ends when the hold expires and runs its hook once")
  func holdExpiresWithoutRejoin() async throws {
    let dataRoot = try makeDataRoot()
    let gate = SleepGate()
    let ended = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base), rejoinHoldSeconds: 60,
      sleep: { seconds in await gate.wait(seconds) },
      onEnded: { session in ended.withLock { $0.append(session.id) } })
    let session = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "efY", trigger: .browserExtension))

    _ = try await registry.end(id: session.id)
    await gate.releaseAll()
    await waitUntil { try await registry.get(id: session.id).state == .ended }

    #expect(ended.withLock { $0 } == [session.id])
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    #expect(timeline.last?.reason == "client")
  }

  @Test("a manual session, or a different meeting's start, is never held")
  func holdOnlyForBrowserClientEnds() async throws {
    let dataRoot = try makeDataRoot()
    let gate = SleepGate()  // never released: the hold must not be what ends it
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base), rejoinHoldSeconds: 60,
      sleep: { seconds in await gate.wait(seconds) })
    let manual = try await registry.start(SessionStartParams(title: "standup"))
    #expect(try await registry.end(id: manual.id).state == .ended)

    let meet = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "a", trigger: .browserExtension))
    _ = try await registry.end(id: meet.id)
    _ = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "b", trigger: .browserExtension))
    #expect(try await registry.get(id: meet.id).state == .ended)
  }

  // MARK: - orphan grace

  @Test("a browser session ends with reason ingest-idle once the grace elapses")
  func orphanGraceExpires() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))
    await registry.ingestStreamOpened(source: "browser:meet:jane")
    await registry.ingestStreamClosed(source: "browser:meet:jane")

    await gate.releaseAll()
    await waitUntil { try await registry.get(id: session.id).state == .ended }

    let final = try await registry.get(id: session.id)
    #expect(final.state == .ended)
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    #expect(timeline.last?.event == "ended")
    #expect(timeline.last?.reason == "ingest-idle")
  }

  @Test("a stream re-opened within the grace keeps the session active")
  func orphanGraceCancelled() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))
    await registry.ingestStreamOpened(source: "browser:meet:jane")
    await registry.ingestStreamClosed(source: "browser:meet:jane")
    // The worker respawned and the stream came back before the grace ran out.
    await registry.ingestStreamOpened(source: "browser:meet:jane")

    await gate.releaseAll()
    // Give the (now-stale) expiry task a chance to run — it must be a no-op.
    for _ in 0..<50 { await Task.yield() }

    #expect(try await registry.get(id: session.id).state == .active)
  }

  @Test("manual sessions are never auto-ended")
  func manualNeverAutoEnds() async throws {
    let dataRoot = try makeDataRoot()
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base), graceSeconds: 0,
      sleep: { seconds in await gate.wait(seconds) })

    let session = try await registry.start(SessionStartParams(title: "standup", sources: ["mic"]))
    await registry.ingestStreamClosed(source: "mic")
    await gate.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(try await registry.get(id: session.id).state == .active)
  }

  // MARK: - daemon-side ingest linking (the `session` tag on ingest.open)

  @Test("a tagged stream joins the live session's sources, so the grace can end it")
  func taggedStreamLinksIntoLiveSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    // The incident shape: the session declared with no browser sources at all
    // (the client's attendee source upserts never arrived).
    let session = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(session.sources == [])

    let identity = SessionIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", session: identity)

    let linked = try await registry.get(id: session.id)
    #expect(linked.sources == ["browser:meet:jane"])
    let onDisk = try SessionStore.read(sessionID: session.id, dataRoot: dataRoot)
    #expect(onDisk.sources == ["browser:meet:jane"])

    // With membership linked daemon-side, the ingest-idle grace now works.
    await registry.ingestStreamClosed(source: "browser:meet:jane")
    await gate.releaseAll()
    await waitUntil { try await registry.get(id: session.id).state == .ended }
    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    #expect(timeline.last?.reason == "ingest-idle")
  }

  @Test("a foreign tagged stream's close does not start another session's grace clock")
  func foreignTaggedCloseDoesNotScheduleGrace() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    // Session A, live, naming a slot-style (non-unique) source label.
    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:speaker-1"],
        trigger: .browserExtension))

    // Another call's stream reuses the same slot label, tagged with its own
    // identity — whose session.start never arrives (tab closed early). Its
    // close belongs to that identity, not to session A.
    let foreign = SessionIdentity(platform: "meet", externalID: "zzz")
    await registry.ingestStreamOpened(source: "browser:meet:speaker-1", session: foreign)
    await registry.ingestStreamClosed(source: "browser:meet:speaker-1", session: foreign)

    await gate.releaseAll()
    // Give any (wrongly) scheduled expiry a chance to run — it must not exist.
    for _ in 0..<50 { await Task.yield() }

    #expect(try await registry.get(id: session.id).state == .active)
  }

  @Test("a tagged stream opened before session.start is claimed at start")
  func taggedStreamBeforeStartIsClaimed() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let identity = SessionIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", session: identity)

    let session = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(session.sources == ["browser:meet:jane"])
  }

  @Test("an idempotent re-declare also claims pending tagged streams")
  func redeclareClaimsPendingLinks() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let started = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    // Tagged open under a *different* identity: stashed, not linked here.
    await registry.ingestStreamOpened(
      source: "browser:meet:other", session: SessionIdentity(platform: "meet", externalID: "xyz"))
    #expect(try await registry.get(id: started.id).sources == [])

    // A respawned worker re-declares; a stream tagged with this identity that
    // opened while no record existed is claimed by the re-declare.
    await registry.ingestStreamOpened(
      source: "browser:meet:jane", session: SessionIdentity(platform: "meet", externalID: "abc"))
    let redeclared = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(redeclared.id == started.id)
    #expect(redeclared.sources == ["browser:meet:jane"])
  }

  @Test("a tagged stream that closes before its session.start links nothing")
  func pendingLinkDroppedOnClose() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let identity = SessionIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", session: identity)
    await registry.ingestStreamClosed(source: "browser:meet:jane")

    let session = try await registry.start(
      SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(session.sources == [])
  }

  // MARK: - browser-audio watchdog

  @Test("warns when a multi-party roster runs with no browser source")
  func browserAudioMissingWarns() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let logged = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      sleep: { seconds in await gate.wait(seconds) },
      log: { line in logged.withLock { $0.append(line) } })

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["mic"], trigger: .browserExtension))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "devices/1", displayName: "Host"))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "devices/2", displayName: "Guest"))

    await gate.releaseAll()
    await waitUntil {
      logged.withLock { $0.contains { $0.contains("session.browser_audio_missing") } }
    }

    let warnings = logged.withLock { $0.filter { $0.contains("session.browser_audio_missing") } }
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("named_attendees=2") == true)
  }

  @Test("stays quiet when a browser source opened")
  func browserAudioPresentStaysQuiet() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let logged = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      log: { line in logged.withLock { $0.append(line) } })

    // No-op sleep (the helper default): every armed check fires immediately,
    // so absence of the warning after the upserts is a real negative.
    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["mic", "browser:meet:speaker-1"],
        trigger: .browserExtension))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "devices/1", displayName: "Host"))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "devices/2", displayName: "Guest"))
    for _ in 0..<50 { await Task.yield() }

    #expect(logged.withLock { !$0.contains { $0.contains("session.browser_audio_missing") } })
  }

  @Test("stays quiet while the roster has fewer than two named attendees")
  func browserAudioSoloStaysQuiet() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let logged = Mutex<[String]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      log: { line in logged.withLock { $0.append(line) } })

    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: ["mic"], trigger: .browserExtension))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(session: session.id, id: "devices/1", displayName: "Host"))
    for _ in 0..<50 { await Task.yield() }

    #expect(logged.withLock { !$0.contains { $0.contains("session.browser_audio_missing") } })
  }
}

/// A controllable stand-in for the registry's sleep seam: waiters block until
/// released, so grace-timer tests drive expiry explicitly instead of racing
/// real time.
private actor SleepGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func wait(_ seconds: Double) async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func releaseAll() {
    released = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}

/// Polls an async condition without real-time sleeps.
private func waitUntil(
  _ condition: @Sendable () async throws -> Bool
) async {
  for _ in 0..<1_000 {
    if (try? await condition()) == true { return }
    await Task.yield()
  }
}

/// Reconciliation at `session.end`: the derivation that used to be an
/// implicit, irreversible side effect of whichever live correlation won a
/// race now runs once, over the final roster, and is persisted.
@Suite("SessionRegistry roster reconciliation")
struct SessionRegistryReconciliationTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func makeRegistry(_ clock: ManualClock, dataRoot: URL) -> SessionRegistry {
    SessionRegistry(
      dataRoot: dataRoot, clock: clock, makeID: { "session-1" }, graceSeconds: 120,
      sleep: { _ in }, knownSourceIDs: { [] })
  }

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionRegistryReconcile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A browser session in the shape the 2026-08-12 call had: you join first,
  /// one other person joins, and a remote track ends up bound to your device.
  private func endMisattributedCall(
    title: String? = nil, dataRoot: URL, clock: ManualClock
  ) async throws -> Session {
    let registry = makeRegistry(clock, dataRoot: dataRoot)
    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "wUE9lE2sg5YB", title: title,
        trigger: .browserExtension))
    clock.advance(by: 3)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/404", displayName: "Tom Elliot",
        joined: clock.now()))
    clock.advance(by: 50)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/403", displayName: "Matthew Barras",
        joined: clock.now()))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/404",
        source: SourceID("browser:meet:devices-404")))
    clock.advance(by: 2000)
    return try await registry.end(id: session.id)
  }

  @Test("session.end reconciles the roster and persists the speaker map")
  func reconcilesAtEnd() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let ended = try await endMisattributedCall(dataRoot: dataRoot, clock: ManualClock(base))

    #expect(ended.speakers.map { $0.name } == ["Matthew Barras"])
    #expect(ended.speakers.map { $0.source.rawValue } == ["browser:meet:devices-404"])
    #expect(ended.attendees.first { $0.id == "devices/404" }?.isLocal == true)
    #expect(!ended.warnings.isEmpty)
    // The map records which reconciler produced it, so a later `transcribe`
    // can tell a current map from one an older derivation left behind.
    #expect(ended.reconcilerVersion == RosterReconciler.version)
  }

  @Test("a wrong self latch is revised at session end, with the evidence persisted")
  func revisesWrongSelfLatch() async throws {
    // The upsert latch is set-once by design (a client omitting `self` must
    // not un-flag anyone), so a flag that landed on the wrong row used to be
    // wrong forever. Reconciliation is the one place with the evidence to
    // revise it: here the *remote* participant arrives flagged as you.
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let clock = ManualClock(base)
    let registry = makeRegistry(clock, dataRoot: dataRoot)
    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "wUE9lE2sg5YB", trigger: .browserExtension))
    clock.advance(by: 3)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/404", displayName: "Tom Elliot",
        joined: clock.now()))
    clock.advance(by: 50)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/403", displayName: "Matthew Barras",
        joined: clock.now(), source: SourceID("browser:meet:devices-403"), isLocal: true))
    clock.advance(by: 2000)
    let ended = try await registry.end(id: session.id)

    // The latch moved: the flag lands on the actual local participant and is
    // cleared from the row the client mis-flagged.
    #expect(ended.attendees.first { $0.id == "devices/404" }?.isLocal == true)
    #expect(ended.attendees.first { $0.id == "devices/403" }?.isLocal == false)
    // The correct binding survives, so the call is attributed to the person
    // actually speaking on the track.
    #expect(
      ended.speakers.contains {
        $0.source == SourceID("browser:meet:devices-403") && $0.name == "Matthew Barras"
      })
    // The evidence for the revision is persisted with the session.
    #expect(ended.warnings.contains { $0.contains("marked Matthew Barras as you") })
  }

  @Test("an unnamed session is titled from the roster rather than the meeting id")
  func titlesFromRoster() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let ended = try await endMisattributedCall(dataRoot: dataRoot, clock: ManualClock(base))

    #expect(ended.title == "Matthew Barras")
  }

  /// The window title is the first preference: a name scraped from the tab
  /// (or typed by hand) reached the session as a title, and the roster
  /// fallback exists only for a session that never got one.
  @Test("a title the meeting already had is never replaced by the roster's")
  func keepsAnEstablishedTitle() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let ended = try await endMisattributedCall(
      title: "Matt / Tom weekly 1:1", dataRoot: dataRoot, clock: ManualClock(base))

    #expect(ended.title == "Matt / Tom weekly 1:1")
  }

  @Test("session.end consumes the attribution log's binding hints for track-handle sources")
  func consumesAttributionHints() async throws {
    // Track-scoped sources (R3) with THREE people on the call: counting can
    // force nothing, so only the attribution log's identity links can name
    // the sources.
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let clock = ManualClock(base)
    let registry = makeRegistry(clock, dataRoot: dataRoot)
    let identity = SessionIdentity(platform: "meet", externalID: "wUE9lE2sg5YB")
    let session = try await registry.start(
      SessionStartParams(
        platform: "meet", externalID: "wUE9lE2sg5YB", trigger: .browserExtension))
    clock.advance(by: 3)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/404", displayName: "Tom Elliot",
        joined: clock.now(), origin: .platform, isLocal: true))
    clock.advance(by: 50)
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/403", displayName: "Ana Flores",
        joined: clock.now(), origin: .platform))
    _ = try await registry.upsertAttendee(
      SessionAttendeeParams(
        session: session.id, id: "devices/402", displayName: "Bram Okafor",
        joined: clock.now(), origin: .platform))
    // The capture layer's track-handle rows and their sources.
    for handle in ["t1", "t2"] {
      _ = try await registry.upsertAttendee(
        SessionAttendeeParams(
          session: session.id, id: handle, joined: clock.now(), origin: .synthetic))
      await registry.ingestStreamOpened(
        source: SourceID("browser:meet:\(handle)"), session: identity)
    }
    // The flight recorder's identity links, as the browser shipped them.
    try SessionAttributionLog.append(
      lines: [
        #"{"schema":1,"type":"provisional-binding","t":1723500000100,"trackId":"trk-1","deviceId":"devices/403","correlator":"dom","confirmations":2,"outcome":"bound"}"#,
        #"{"schema":1,"type":"identity-link","t":1723500000200,"trackId":"trk-1","captureId":"t1","participantId":"devices/403"}"#,
        #"{"schema":1,"type":"identity-link","t":1723500000300,"trackId":"trk-2","captureId":"t2","participantId":"devices/402"}"#,
      ], dataRoot: dataRoot, sessionID: session.id)
    clock.advance(by: 2000)
    let ended = try await registry.end(id: session.id)

    #expect(
      ended.speakers.contains {
        $0.source == SourceID("browser:meet:t1") && $0.name == "Ana Flores"
          && $0.confidence == .correlated
      })
    #expect(
      ended.speakers.contains {
        $0.source == SourceID("browser:meet:t2") && $0.name == "Bram Okafor"
      })
  }

  @Test("the reconciled session round-trips through session.toml")
  func persistsAcrossReload() async throws {
    let dataRoot = try makeDataRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let clock = ManualClock(base)
    let ended = try await endMisattributedCall(dataRoot: dataRoot, clock: clock)

    let reloaded = makeRegistry(clock, dataRoot: dataRoot)
    await reloaded.loadFromDisk()
    let recovered = try await reloaded.get(id: ended.id)
    #expect(recovered.speakers == ended.speakers)
    #expect(recovered.warnings == ended.warnings)
    #expect(recovered.title == "Matthew Barras")
    #expect(recovered.reconcilerVersion == RosterReconciler.version)
  }
}
