import Testing

@testable import EarsIPC

@Suite("EarsIPC")
struct EarsIPCTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsIPC.version.isEmpty)
  }
}
