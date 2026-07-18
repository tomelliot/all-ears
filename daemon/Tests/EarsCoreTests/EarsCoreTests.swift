import Testing

@testable import EarsCore

@Suite("EarsCore")
struct EarsCoreTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsCore.version.isEmpty)
  }
}
