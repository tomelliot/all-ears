import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Real-temp-directory tests for ``MeetingRegistry``, the v2 meeting
/// lifecycle owner: idempotent `meeting.start`, pause/resume interval
/// bookkeeping, restart recovery, the orphan grace timer, rename
/// compare-and-set, and the `[speakers]` write-back at `meeting.end` — with
/// a ``ManualClock`` and an injected sleep so no test touches real time.
@Suite("MeetingRegistry")
struct MeetingRegistryTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetingRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRegistry(
    dataRoot: URL,
    clock: ManualClock,
    bus: EventBus? = nil,
    graceSeconds: Double = 120,
    sleep: (@Sendable (Double) async -> Void)? = nil,
    onEnded: MeetingRegistry.EndedHook? = nil,
    localBrowserSources: [SourceID] = [],
    knownSourceIDs: @escaping @Sendable () async -> Set<SourceID> = { [] }
  ) -> MeetingRegistry {
    let ids = Mutex(0)
    return MeetingRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "meeting-\(next)"
        }
      },
      bus: bus,
      graceSeconds: graceSeconds,
      sleep: sleep ?? { _ in },
      onEnded: onEnded,
      localBrowserSources: localBrowserSources,
      knownSourceIDs: knownSourceIDs)
  }

  // MARK: - start

  @Test("start persists an active meeting with one open interval")
  func startPersists() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let meeting = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))

    #expect(meeting.state == .active)
    #expect(meeting.intervals == [MeetingInterval(start: base)])
    #expect(meeting.trigger == .browserExtension)
    let onDisk = try MeetingStore.read(meetingID: meeting.id, dataRoot: dataRoot)
    #expect(onDisk.state == .active)
    #expect(onDisk.intervals.first?.end == nil)
    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: meeting.id)
    #expect(timeline.map(\.event) == ["started", "interval_opened"])
  }

  @Test("a browser meeting folds in the configured local sources it can capture")
  func startInjectsLocalBrowserSources() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      localBrowserSources: ["mic"],
      knownSourceIDs: { ["mic", "system"] })

    let meeting = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))

    // Declared sources keep their order; the capturable local source appends.
    #expect(meeting.sources == ["browser:meet:jane", "mic"])
    let onDisk = try MeetingStore.read(meetingID: meeting.id, dataRoot: dataRoot)
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

    let meeting = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", trigger: .browserExtension))

    #expect(meeting.sources == [])
  }

  @Test("local sources are folded into browser meetings only, not manual ones")
  func startInjectsForBrowserTriggerOnly() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      localBrowserSources: ["mic"],
      knownSourceIDs: { ["mic"] })

    let manual = try await registry.start(
      MeetingStartParams(title: "standup", sources: ["app:zoom"]))

    // A manual/CLI meeting names its own sources; mic is not force-added.
    #expect(manual.trigger == .manual)
    #expect(manual.sources == ["app:zoom"])
  }

  @Test("start is idempotent on identity: re-declaring returns the same live meeting")
  func startIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let first = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc"))
    let second = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", title: "ignored on re-declare"))
    let other = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "different"))

    #expect(second.id == first.id)
    #expect(second.title == first.title)
    #expect(other.id != first.id)
  }

  @Test("re-declaring after end starts a fresh meeting under the same identity")
  func rejoinAfterEnd() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let first = try await registry.start(MeetingStartParams(platform: "meet", externalID: "abc"))
    _ = try await registry.end(id: first.id)
    let second = try await registry.start(MeetingStartParams(platform: "meet", externalID: "abc"))

    #expect(second.id != first.id)
    #expect(second.state == .active)
  }

  @Test("a manual meeting (no identity) is first-class")
  func manualMeeting() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))

    let meeting = try await registry.start(
      MeetingStartParams(title: "standup", sources: ["mic"]))

    #expect(meeting.identity == nil)
    #expect(meeting.title == "standup")
    #expect(meeting.trigger == .manual)
    #expect(!meeting.isBrowserMeeting)
  }

  // MARK: - single active meeting invariant (#27)

  @Test("starting a meeting supersedes any live meeting (reason superseded)")
  func startSupersedesLiveMeeting() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    // A stale meeting left live (the 2026-07-23 chain: one real, one stale).
    let stale = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "stale", sources: ["browser:meet:a"],
        trigger: .browserExtension))
    clock.advance(by: 300)
    let real = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "real", sources: ["browser:meet:b"],
        trigger: .browserExtension))

    #expect(real.id != stale.id)
    #expect(real.state == .active)

    let staleFinal = try await registry.get(id: stale.id)
    #expect(staleFinal.state == .ended)
    let staleTimeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: stale.id)
    #expect(staleTimeline.last?.event == "ended")
    #expect(staleTimeline.last?.reason == "superseded")

    // Exactly one live meeting remains — the invariant holds.
    let live = await registry.list().filter { $0.state != .ended }
    #expect(live.map(\.id) == [real.id])
  }

  @Test("a duplicate start for the same identity does not supersede or restart the meeting")
  func duplicateStartSameIdentityIsIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let first = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    clock.advance(by: 5)
    let again = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))

    #expect(again.id == first.id)
    #expect(again.state == .active)
    // Not restarted: still a single open interval, and never ended.
    #expect(again.intervals.count == 1)
    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: first.id)
    #expect(!timeline.map(\.event).contains("ended"))
  }

  @Test("supersede stops the old meeting's capture before it starts the new meeting's")
  func supersedeReleasesCaptureBeforeStartingNew() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let calls = Mutex<[String]>([])
    let ids = Mutex(0)
    let registry = MeetingRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "meeting-\(next)"
        }
      },
      startCapture: { id, _ in calls.withLock { $0.append("start:\(id)") } },
      stopCapture: { id, _ in calls.withLock { $0.append("stop:\(id)") } })

    let a = try await registry.start(MeetingStartParams(title: "a", sources: ["mic"]))
    let b = try await registry.start(MeetingStartParams(title: "b", sources: ["mic"]))

    // The superseded meeting releases the shared mic (stop) before the
    // successor claims it (start) — so the new meeting rebuilds against its own
    // directory, never the old one's.
    #expect(calls.withLock { $0 } == ["start:\(a.id)", "stop:\(a.id)", "start:\(b.id)"])
  }

  @Test("boot resumes only the latest-started meeting; older active records are orphaned")
  func bootSweepResumesOneOrphansRest() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base.advanced(by: 10_000))

    // Two meetings left `active` on disk by a previous daemon instance.
    let stale = Meeting(
      id: "stale", identity: MeetingIdentity(platform: "meet", externalID: "old"),
      title: "old", state: .active, started: base,
      intervals: [MeetingInterval(start: base)], sources: ["browser:meet:a"],
      trigger: .browserExtension)
    let recent = Meeting(
      id: "recent", identity: MeetingIdentity(platform: "meet", externalID: "new"),
      title: "new", state: .active, started: base.advanced(by: 500),
      intervals: [MeetingInterval(start: base.advanced(by: 500))], sources: ["browser:meet:b"],
      trigger: .browserExtension)
    try MeetingStore.write(stale, dataRoot: dataRoot)
    try MeetingStore.write(recent, dataRoot: dataRoot)

    let startCaptures = Mutex<[String]>([])
    let ids = Mutex(0)
    let registry = MeetingRegistry(
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
    let staleTimeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: "stale")
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
    let started = try await registry.start(MeetingStartParams(title: "standup"))

    clock.advance(by: 750)
    let paused = try await registry.pause(id: started.id)
    #expect(paused.state == .paused)
    #expect(paused.intervals == [MeetingInterval(start: base, end: base.advanced(by: 750))])

    clock.advance(by: 455)
    let resumed = try await registry.resume(id: started.id)
    #expect(resumed.state == .active)
    #expect(resumed.intervals.count == 2)
    #expect(resumed.intervals[1] == MeetingInterval(start: base.advanced(by: 1205)))

    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: started.id)
    #expect(
      timeline.map(\.event)
        == ["started", "interval_opened", "interval_closed", "interval_opened"])
  }

  @Test("pause when already paused (and resume when active) are converging no-ops")
  func pauseResumeIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))
    let started = try await registry.start(MeetingStartParams(title: "standup"))

    let once = try await registry.resume(id: started.id)  // already active
    #expect(once.intervals.count == 1)
    _ = try await registry.pause(id: started.id)
    let twice = try await registry.pause(id: started.id)  // already paused
    #expect(twice.state == .paused)
    #expect(twice.intervals.count == 1)
  }

  @Test("lifecycle verbs on an ended meeting fail with the ended error")
  func endedMeetingRejectsLifecycle() async throws {
    let dataRoot = try makeDataRoot()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base))
    let meeting = try await registry.start(MeetingStartParams(title: "standup"))
    _ = try await registry.end(id: meeting.id)

    await #expect(throws: MeetingRegistryError.ended(meeting.id)) {
      try await registry.pause(id: meeting.id)
    }
    await #expect(throws: MeetingRegistryError.notFound("nope")) {
      try await registry.resume(id: "nope")
    }
  }

  // MARK: - end + materialization

  @Test("end materializes one closed session per interval with the roster's speakers map")
  func endMaterializes() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let endedMeetings = Mutex<[(Meeting, [SessionDescriptor])]>([])
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock,
      onEnded: { meeting, sessions in
        endedMeetings.withLock { $0.append((meeting, sessions)) }
      })

    let started = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", sources: ["mic", "browser:meet:jane"],
        trigger: .browserExtension))
    _ = try await registry.upsertAttendee(
      MeetingAttendeeParams(
        meeting: started.id, id: "spaces/x/devices/y", displayName: "Jane Doe",
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

    let hooks = endedMeetings.withLock { $0 }
    #expect(hooks.count == 1)
    let sessions = hooks[0].1
    #expect(sessions.count == 2)
    for session in sessions {
      #expect(session.state == .closed)
      #expect(session.slug == started.id)
      #expect(session.trigger == .browserExtension)
      #expect(session.speakers == ["browser:meet:jane": "Jane Doe"])
      let onDisk = try SessionStore.read(sessionID: session.id, dataRoot: dataRoot)
      #expect(onDisk == session)
    }

    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: started.id)
    #expect(timeline.last?.event == "ended")
    #expect(timeline.last?.reason == "client")
  }

  @Test("end is idempotent: a second end returns the final state without re-materializing")
  func endIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let hookCount = Mutex(0)
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base),
      onEnded: { _, _ in hookCount.withLock { $0 += 1 } })
    let meeting = try await registry.start(MeetingStartParams(title: "standup"))

    _ = try await registry.end(id: meeting.id)
    let again = try await registry.end(id: meeting.id)

    #expect(again.state == .ended)
    #expect(hookCount.withLock { $0 } == 1)
  }

  // MARK: - meeting-scoped capture

  @Test("capture starts on meeting start and stops on meeting end")
  func meetingScopesCapture() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let startCalls = Mutex<[[SourceID]]>([])
    let stopCalls = Mutex<[[SourceID]]>([])
    let ids = Mutex(0)
    let registry = MeetingRegistry(
      dataRoot: dataRoot,
      clock: clock,
      makeID: {
        ids.withLock { next in
          next += 1
          return "meeting-\(next)"
        }
      },
      startCapture: { _, sources in startCalls.withLock { $0.append(sources) } },
      stopCapture: { _, sources in stopCalls.withLock { $0.append(sources) } })

    let meeting = try await registry.start(
      MeetingStartParams(title: "standup", sources: ["mic"]))
    #expect(startCalls.withLock { $0 } == [["mic"]])
    #expect(stopCalls.withLock { $0 }.isEmpty)

    _ = try await registry.end(id: meeting.id)
    #expect(stopCalls.withLock { $0 } == [["mic"]])
  }

  @Test("markTranscriptCompleted records the completion instant durably")
  func marksTranscriptCompleted() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let meeting = try await registry.start(MeetingStartParams(title: "standup"))
    _ = try await registry.end(id: meeting.id)
    #expect(try await registry.get(id: meeting.id).transcriptCompleted == nil)

    await registry.markTranscriptCompleted(id: meeting.id, at: base.advanced(by: 300))

    #expect(try await registry.get(id: meeting.id).transcriptCompleted == base.advanced(by: 300))
    // Durable: read straight back off disk.
    let reloaded = try MeetingStore.read(meetingID: meeting.id, dataRoot: dataRoot)
    #expect(reloaded.transcriptCompleted == base.advanced(by: 300))
  }

  // MARK: - rename / attendee

  @Test("rename is a compare-and-set under if_rev")
  func renameConflict() async throws {
    let dataRoot = try makeDataRoot()
    let bus = EventBus()
    let registry = makeRegistry(dataRoot: dataRoot, clock: ManualClock(base), bus: bus)
    let meeting = try await registry.start(MeetingStartParams(title: "standup"))

    let renamed = try await registry.rename(
      id: meeting.id, title: "Weekly sync", ifRev: meeting.rev)
    #expect(renamed.title == "Weekly sync")
    #expect(renamed.rev > meeting.rev)

    await #expect(throws: MeetingRegistryError.self) {
      _ = try await registry.rename(id: meeting.id, title: "stale", ifRev: meeting.rev)
    }
  }

  @Test("attendee upserts merge fields and join the meeting's source list")
  func attendeeUpsert() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)
    let meeting = try await registry.start(MeetingStartParams(platform: "meet", externalID: "a"))

    _ = try await registry.upsertAttendee(
      MeetingAttendeeParams(meeting: meeting.id, id: "p1", displayName: "Jane Doe"))
    clock.advance(by: 60)
    let linked = try await registry.upsertAttendee(
      MeetingAttendeeParams(meeting: meeting.id, id: "p1", source: "browser:meet:jane"))

    #expect(linked.attendees.count == 1)
    let attendee = linked.attendees[0]
    #expect(attendee.displayName == "Jane Doe")  // earlier field kept
    #expect(attendee.source == "browser:meet:jane")
    #expect(attendee.joined == base)  // stamped at first upsert
    #expect(linked.sources.contains("browser:meet:jane"))

    clock.advance(by: 60)
    let left = try await registry.upsertAttendee(
      MeetingAttendeeParams(meeting: meeting.id, id: "p1", left: clock.now()))
    #expect(left.attendees[0].left == base.advanced(by: 120))
    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: meeting.id)
    #expect(timeline.map(\.event).contains("attendee_joined"))
    #expect(timeline.last?.event == "attendee_left")
  }

  // MARK: - restart recovery

  @Test("an active meeting with an open interval survives a daemon restart")
  func restartRecovery() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let first = makeRegistry(dataRoot: dataRoot, clock: clock)
    let started = try await first.start(
      MeetingStartParams(platform: "meet", externalID: "abc"))

    // A second registry over the same data root — a fresh daemon boot.
    let second = makeRegistry(dataRoot: dataRoot, clock: clock)
    await second.loadFromDisk()

    let reloaded = try await second.get(id: started.id)
    #expect(reloaded.state == .active)
    #expect(reloaded.intervals.first?.end == nil)
    // Idempotency index reloads too: re-declaring converges on the same id.
    let redeclared = try await second.start(
      MeetingStartParams(platform: "meet", externalID: "abc"))
    #expect(redeclared.id == started.id)
  }

  // MARK: - orphan grace

  @Test("a browser meeting ends with reason ingest-idle once the grace elapses")
  func orphanGraceExpires() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    let meeting = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))
    await registry.ingestStreamOpened(source: "browser:meet:jane")
    await registry.ingestStreamClosed(source: "browser:meet:jane")

    await gate.releaseAll()
    await waitUntil { try await registry.get(id: meeting.id).state == .ended }

    let final = try await registry.get(id: meeting.id)
    #expect(final.state == .ended)
    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: meeting.id)
    #expect(timeline.last?.event == "ended")
    #expect(timeline.last?.reason == "ingest-idle")
  }

  @Test("a stream re-opened within the grace keeps the meeting active")
  func orphanGraceCancelled() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    let meeting = try await registry.start(
      MeetingStartParams(
        platform: "meet", externalID: "abc", sources: ["browser:meet:jane"],
        trigger: .browserExtension))
    await registry.ingestStreamOpened(source: "browser:meet:jane")
    await registry.ingestStreamClosed(source: "browser:meet:jane")
    // The worker respawned and the stream came back before the grace ran out.
    await registry.ingestStreamOpened(source: "browser:meet:jane")

    await gate.releaseAll()
    // Give the (now-stale) expiry task a chance to run — it must be a no-op.
    for _ in 0..<50 { await Task.yield() }

    #expect(try await registry.get(id: meeting.id).state == .active)
  }

  @Test("manual meetings are never auto-ended")
  func manualNeverAutoEnds() async throws {
    let dataRoot = try makeDataRoot()
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: ManualClock(base), graceSeconds: 0,
      sleep: { seconds in await gate.wait(seconds) })

    let meeting = try await registry.start(MeetingStartParams(title: "standup", sources: ["mic"]))
    await registry.ingestStreamClosed(source: "mic")
    await gate.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(try await registry.get(id: meeting.id).state == .active)
  }

  // MARK: - daemon-side ingest linking (the `meeting` tag on ingest.open)

  @Test("a tagged stream joins the live meeting's sources, so the grace can end it")
  func taggedStreamLinksIntoLiveMeeting() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let gate = SleepGate()
    let registry = makeRegistry(
      dataRoot: dataRoot, clock: clock, graceSeconds: 120,
      sleep: { seconds in await gate.wait(seconds) })

    // The incident shape: the meeting declared with no browser sources at all
    // (the client's attendee source upserts never arrived).
    let meeting = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(meeting.sources == [])

    let identity = MeetingIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", meeting: identity)

    let linked = try await registry.get(id: meeting.id)
    #expect(linked.sources == ["browser:meet:jane"])
    let onDisk = try MeetingStore.read(meetingID: meeting.id, dataRoot: dataRoot)
    #expect(onDisk.sources == ["browser:meet:jane"])

    // With membership linked daemon-side, the ingest-idle grace now works.
    await registry.ingestStreamClosed(source: "browser:meet:jane")
    await gate.releaseAll()
    await waitUntil { try await registry.get(id: meeting.id).state == .ended }
    let timeline = MeetingEventLog.readAll(dataRoot: dataRoot, meetingID: meeting.id)
    #expect(timeline.last?.reason == "ingest-idle")
  }

  @Test("a tagged stream opened before meeting.start is claimed at start")
  func taggedStreamBeforeStartIsClaimed() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let identity = MeetingIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", meeting: identity)

    let meeting = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(meeting.sources == ["browser:meet:jane"])
  }

  @Test("an idempotent re-declare also claims pending tagged streams")
  func redeclareClaimsPendingLinks() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let started = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    // Tagged open under a *different* identity: stashed, not linked here.
    await registry.ingestStreamOpened(
      source: "browser:meet:other", meeting: MeetingIdentity(platform: "meet", externalID: "xyz"))
    #expect(try await registry.get(id: started.id).sources == [])

    // A respawned worker re-declares; a stream tagged with this identity that
    // opened while no record existed is claimed by the re-declare.
    await registry.ingestStreamOpened(
      source: "browser:meet:jane", meeting: MeetingIdentity(platform: "meet", externalID: "abc"))
    let redeclared = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(redeclared.id == started.id)
    #expect(redeclared.sources == ["browser:meet:jane"])
  }

  @Test("a tagged stream that closes before its meeting.start links nothing")
  func pendingLinkDroppedOnClose() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(base)
    let registry = makeRegistry(dataRoot: dataRoot, clock: clock)

    let identity = MeetingIdentity(platform: "meet", externalID: "abc")
    await registry.ingestStreamOpened(source: "browser:meet:jane", meeting: identity)
    await registry.ingestStreamClosed(source: "browser:meet:jane")

    let meeting = try await registry.start(
      MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension))
    #expect(meeting.sources == [])
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
