import Testing

@testable import EarsCore

@Suite("Instant")
struct InstantTests {
  @Test("orders by seconds since epoch")
  func ordering() {
    let earlier = Instant(secondsSinceEpoch: 100)
    let later = Instant(secondsSinceEpoch: 200)
    #expect(earlier < later)
    #expect(later > earlier)
    #expect(earlier == Instant(secondsSinceEpoch: 100))
  }

  @Test("measures the interval between two instants")
  func interval() {
    let start = Instant(secondsSinceEpoch: 10)
    let end = Instant(secondsSinceEpoch: 42.5)
    #expect(end.interval(since: start) == 32.5)
    #expect(start.interval(since: end) == -32.5)
  }

  @Test("advances by a number of seconds")
  func advancing() {
    let base = Instant(secondsSinceEpoch: 1_000)
    #expect(base.advanced(by: 30) == Instant(secondsSinceEpoch: 1_030))
    #expect(base.advanced(by: -1) == Instant(secondsSinceEpoch: 999))
  }
}

@Suite("TimeRange")
struct TimeRangeTests {
  private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: Instant(secondsSinceEpoch: start), end: Instant(secondsSinceEpoch: end))
  }

  @Test("duration is the gap between start and end")
  func duration() {
    #expect(range(10, 40).duration == 30)
    #expect(range(5, 5).duration == 0)
  }

  @Test("contains is half-open on the end")
  func contains() {
    let r = range(10, 20)
    #expect(r.contains(Instant(secondsSinceEpoch: 10)))
    #expect(r.contains(Instant(secondsSinceEpoch: 15)))
    #expect(!r.contains(Instant(secondsSinceEpoch: 20)))
    #expect(!r.contains(Instant(secondsSinceEpoch: 9)))
  }

  @Test("overlapping ranges share an interior instant")
  func overlaps() {
    #expect(range(10, 20).overlaps(range(15, 25)))
    #expect(range(15, 25).overlaps(range(10, 20)))
    #expect(range(10, 30).overlaps(range(15, 20)))  // nested
  }

  @Test("touching and disjoint ranges do not overlap")
  func nonOverlaps() {
    #expect(!range(10, 20).overlaps(range(20, 30)))  // touching, half-open
    #expect(!range(10, 20).overlaps(range(30, 40)))  // disjoint
  }
}
