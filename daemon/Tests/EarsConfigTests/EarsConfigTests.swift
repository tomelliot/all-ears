import Testing

@testable import EarsConfig

@Suite("EarsConfig")
struct EarsConfigTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsConfig.version.isEmpty)
  }
}
