import Testing

@testable import EarsLogging

@Suite("EarsLogging")
struct EarsLoggingTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsLogging.version.isEmpty)
  }
}
