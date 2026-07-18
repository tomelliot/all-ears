import Testing

@testable import EarsLogging

/// Smoke tests for the untested environment glue (`docs/logging.md`'s
/// TTY-detection requirement is "a real environment check, not something to
/// fake/inject"). Everything that branches on these seams' *output* is
/// tested elsewhere against a fixed fake; these just confirm the real
/// conformances don't crash and return a `Bool`.
@Suite("Environment seams")
struct EnvironmentSeamsTests {
  @Test("RealTTYDetector answers without crashing")
  func realTTYDetectorAnswers() {
    let detector = RealTTYDetector()
    _ = detector.isStderrATTY
  }

  @Test("RealStderrWriter writes without crashing")
  func realStderrWriterWrites() {
    RealStderrWriter().writeLine("EarsLoggingTests: environment seam smoke test")
  }
}
