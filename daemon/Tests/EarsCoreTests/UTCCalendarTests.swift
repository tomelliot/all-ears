import Testing

@testable import EarsCore

/// The pure epoch-seconds → UTC calendar conversion the transcript renderer
/// depends on for frontmatter timestamps and Markdown heading times. Expected
/// values cross-checked against `date -j -u -f "%Y-%m-%dT%H:%M:%SZ" ... "+%s"`.
@Suite("UTCCalendar")
struct UTCCalendarTests {
  @Test("epoch zero is the Unix epoch")
  func epochZero() {
    #expect(UTCCalendar.iso8601(Instant(secondsSinceEpoch: 0)) == "1970-01-01T00:00:00Z")
  }

  @Test("a mid-2026 instant round-trips to the doc's example timestamps")
  func docExampleInstants() {
    #expect(
      UTCCalendar.iso8601(Instant(secondsSinceEpoch: 1_784_284_200)) == "2026-07-17T10:30:00Z")
    #expect(
      UTCCalendar.iso8601(Instant(secondsSinceEpoch: 1_784_286_120)) == "2026-07-17T11:02:00Z")
    #expect(
      UTCCalendar.iso8601(Instant(secondsSinceEpoch: 1_784_286_134)) == "2026-07-17T11:02:14Z")
  }

  @Test("a leap day formats correctly")
  func leapDay() {
    #expect(UTCCalendar.iso8601(Instant(secondsSinceEpoch: 951_825_600)) == "2000-02-29T12:00:00Z")
  }

  @Test("the second before an epoch year boundary")
  func yearBoundary() {
    #expect(UTCCalendar.iso8601(Instant(secondsSinceEpoch: 946_684_799)) == "1999-12-31T23:59:59Z")
  }

  @Test("timeOfDay drops the date, matching a Markdown heading's [HH:MM:SS]")
  func timeOfDayOnly() {
    #expect(UTCCalendar.timeOfDay(Instant(secondsSinceEpoch: 1_784_284_204)) == "10:30:04")
  }

  @Test("fractional seconds truncate towards the start of the second")
  func fractionalSecondsTruncate() {
    #expect(
      UTCCalendar.iso8601(Instant(secondsSinceEpoch: 1_784_284_200.9)) == "2026-07-17T10:30:00Z")
  }
}
