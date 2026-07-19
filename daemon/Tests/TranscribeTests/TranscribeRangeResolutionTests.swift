import EarsCore
import Testing

@testable import transcribe

@Suite("TranscribeRangeResolution")
struct TranscribeRangeResolutionTests {
  private let now = Instant(secondsSinceEpoch: 1_784_284_200)

  private func resolve(
    last: String? = nil, from: String? = nil, to: String? = nil, session: String? = nil,
    sessionReader: (String) -> Result<SessionDescriptor, TranscribeRangeResolution.RangeError> = {
      _ in .failure(.unknownSession("unused"))
    }
  ) -> Result<TranscribeRangeResolution.Resolved, TranscribeRangeResolution.RangeError> {
    TranscribeRangeResolution.resolve(
      last: last, from: from, to: to, session: session, now: now, sessionReader: sessionReader)
  }

  private static func fixtureDescriptor(
    id: String = "2026-07-17T10-30-00Z_standup",
    slug: String = "standup",
    sources: [SourceID] = ["mic"],
    start: Instant,
    end: Instant?,
    vocab: String? = nil,
    preRollSeconds: Int = 0
  ) -> SessionDescriptor {
    SessionDescriptor(
      schema: 1, id: id, slug: slug, sources: sources, start: start, end: end,
      state: end == nil ? .open : .closed, trigger: .manual, vocab: vocab,
      preRollSeconds: preRollSeconds)
  }

  // MARK: - --last

  @Test("--last 20m resolves to a range ending now, 20 minutes long")
  func lastResolvesRangeEndingNow() {
    let result = resolve(last: "20m")
    #expect(result == .success(.init(range: TimeRange(start: now.advanced(by: -1200), end: now))))
  }

  @Test("--last 2h resolves correctly")
  func lastHoursResolves() {
    let result = resolve(last: "2h")
    #expect(result == .success(.init(range: TimeRange(start: now.advanced(by: -7200), end: now))))
  }

  @Test("nothing at all is an error naming that no range was specified")
  func noneIsError() {
    let result = resolve()
    #expect(result == .failure(.noRangeSpecified))
  }

  @Test("a malformed --last value is an error")
  func malformedLastIsError() {
    let result = resolve(last: "not-a-duration")
    guard case .failure(.invalidDuration) = result else {
      Issue.record("expected .invalidDuration, got \(result)")
      return
    }
  }

  @Test("--last 0m is an error naming the range as empty")
  func zeroLastIsEmptyRangeError() {
    let result = resolve(last: "0m")
    #expect(result == .failure(.emptyRange))
  }

  // MARK: - --from/--to

  @Test("--from/--to resolves an explicit ISO-8601 range")
  func fromToResolves() {
    let result = resolve(from: "2026-07-17T10:30:00Z", to: "2026-07-17T11:02:00Z")
    #expect(
      result
        == .success(
          .init(
            range: TimeRange(
              start: Instant(secondsSinceEpoch: 1_784_284_200),
              end: Instant(secondsSinceEpoch: 1_784_286_120)))))
  }

  @Test("--from without --to is an error")
  func fromWithoutToIsError() {
    #expect(resolve(from: "2026-07-17T10:30:00Z") == .failure(.incompleteFromTo))
  }

  @Test("--to without --from is an error")
  func toWithoutFromIsError() {
    #expect(resolve(to: "2026-07-17T11:02:00Z") == .failure(.incompleteFromTo))
  }

  @Test("a malformed --from value names the offending field")
  func malformedFromIsError() {
    let result = resolve(from: "not-a-timestamp", to: "2026-07-17T11:02:00Z")
    #expect(result == .failure(.invalidTimestamp(field: "from", value: "not-a-timestamp")))
  }

  @Test("--from after --to is an empty-range error")
  func fromAfterToIsEmptyRange() {
    let result = resolve(from: "2026-07-17T11:02:00Z", to: "2026-07-17T10:30:00Z")
    #expect(result == .failure(.emptyRange))
  }

  // MARK: - --session

  @Test("--session resolves range, sources, vocab, and the real session id from a closed session")
  func sessionResolvesClosedSession() {
    let descriptor = Self.fixtureDescriptor(
      sources: ["mic", "app:us.zoom.xos"],
      start: Instant(secondsSinceEpoch: 1_784_284_200),
      end: Instant(secondsSinceEpoch: 1_784_286_120),
      vocab: "vocab/standup.txt")

    let result = resolve(session: "2026-07-17T10-30-00Z_standup") { _ in .success(descriptor) }

    #expect(
      result
        == .success(
          .init(
            range: TimeRange(
              start: Instant(secondsSinceEpoch: 1_784_284_200),
              end: Instant(secondsSinceEpoch: 1_784_286_120)),
            sourceIDs: ["mic", "app:us.zoom.xos"],
            vocab: "vocab/standup.txt",
            sessionIdentifier: "2026-07-17T10-30-00Z_standup",
            sessionSlug: "standup")))
  }

  @Test("--session on a still-open session resolves [start, now) rather than erroring")
  func sessionResolvesOpenSessionEndingNow() {
    let descriptor = Self.fixtureDescriptor(start: now.advanced(by: -1800), end: nil)

    let result = resolve(session: "2026-07-17T10-30-00Z_standup") { _ in .success(descriptor) }

    guard case .success(let resolved) = result else {
      Issue.record("expected success, got \(result)")
      return
    }
    #expect(resolved.range == TimeRange(start: descriptor.start, end: now))
  }

  @Test(
    "--session widens the range's start backward by preRollSeconds, without touching descriptor.start"
  )
  func sessionAppliesPreRollWidening() {
    let descriptor = Self.fixtureDescriptor(
      start: Instant(secondsSinceEpoch: 1_784_284_200),
      end: Instant(secondsSinceEpoch: 1_784_286_120),
      preRollSeconds: 15)

    let result = resolve(session: "2026-07-17T10-30-00Z_standup") { _ in .success(descriptor) }

    guard case .success(let resolved) = result else {
      Issue.record("expected success, got \(result)")
      return
    }
    #expect(resolved.range.start == descriptor.start.advanced(by: -15))
    #expect(resolved.range.end == descriptor.end)
    // The descriptor itself is never mutated by resolution.
    #expect(descriptor.start == Instant(secondsSinceEpoch: 1_784_284_200))
  }

  @Test("preRollSeconds == 0 (the default) widens nothing")
  func zeroPreRollWidensNothing() {
    let descriptor = Self.fixtureDescriptor(
      start: Instant(secondsSinceEpoch: 1_784_284_200),
      end: Instant(secondsSinceEpoch: 1_784_286_120))

    let result = resolve(session: "2026-07-17T10-30-00Z_standup") { _ in .success(descriptor) }

    guard case .success(let resolved) = result else {
      Issue.record("expected success, got \(result)")
      return
    }
    #expect(resolved.range.start == descriptor.start)
  }

  @Test("an unknown --session id surfaces the sessionReader's error")
  func unknownSessionIsError() {
    let result = resolve(session: "nonexistent") { id in .failure(.unknownSession(id)) }
    #expect(result == .failure(.unknownSession("nonexistent")))
  }

  // MARK: - Mutual exclusivity

  @Test("--last and --session together is an error")
  func lastAndSessionTogetherIsError() {
    let result = resolve(last: "20m", session: "some-id")
    #expect(result == .failure(.multipleRangeSourcesSpecified))
  }

  @Test("--last and --from/--to together is an error")
  func lastAndFromToTogetherIsError() {
    let result = resolve(last: "20m", from: "2026-07-17T10:30:00Z", to: "2026-07-17T11:02:00Z")
    #expect(result == .failure(.multipleRangeSourcesSpecified))
  }

  @Test("--session and --from/--to together is an error")
  func sessionAndFromToTogetherIsError() {
    let result = resolve(
      from: "2026-07-17T10:30:00Z", to: "2026-07-17T11:02:00Z", session: "some-id")
    #expect(result == .failure(.multipleRangeSourcesSpecified))
  }
}
