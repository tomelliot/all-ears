import Testing

@testable import EarsDaemonKit

@Suite("EarsDaemonKit")
struct EarsDaemonKitTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsDaemonKit.version.isEmpty)
  }
}
