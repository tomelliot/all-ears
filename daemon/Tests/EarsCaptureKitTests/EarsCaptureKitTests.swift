import Testing

@testable import EarsCaptureKit

@Suite("EarsCaptureKit")
struct EarsCaptureKitTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsCaptureKit.version.isEmpty)
  }
}
