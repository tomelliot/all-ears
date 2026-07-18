import Testing

@testable import EarsCore

/// Covers ``FilenameTimestampCodec``: the ISO-8601-with-`:`-replaced-by-`-`
/// form used for chunk filenames and session directory names, per
/// `docs/data-formats.md`.
@Suite("FilenameTimestampCodec")
struct FilenameTimestampCodecTests {
  private let instant = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  @Test("renders the exact filename form from docs/data-formats.md")
  func rendersFilenameForm() {
    #expect(FilenameTimestampCodec.string(for: instant) == "2026-07-17T10-30-00Z")
  }

  @Test("round-trips through string(for:) and parse(_:)")
  func roundTrips() {
    let rendered = FilenameTimestampCodec.string(for: instant)
    #expect(FilenameTimestampCodec.parse(rendered) == instant)
  }

  @Test("truncates sub-second precision, matching whole-second filenames")
  func truncatesSubSeconds() {
    let subSecond = instant.advanced(by: 0.75)
    #expect(FilenameTimestampCodec.string(for: subSecond) == "2026-07-17T10-30-00Z")
  }

  @Test("parses a session directory name, ignoring the trailing slug")
  func parsesSessionDirectoryPrefix() {
    // Session directory names append "_<slug>" after the timestamp
    // (`2026-07-17T10-30-00Z_standup`); the codec only ever sees the
    // timestamp portion callers slice out, so this documents that a
    // trailing suffix after "Z" is rejected rather than silently ignored.
    #expect(FilenameTimestampCodec.parse("2026-07-17T10-30-00Z_standup") == nil)
  }

  @Test("returns nil for an unparsable string")
  func returnsNilForGarbage() {
    #expect(FilenameTimestampCodec.parse("not-a-timestamp") == nil)
  }

  @Test("returns nil for a string with no time component")
  func returnsNilWithNoTComponent() {
    #expect(FilenameTimestampCodec.parse("2026-07-17") == nil)
  }
}
