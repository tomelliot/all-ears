import Testing

@testable import EarsDataStore

@Suite("EarsDataStore")
struct EarsDataStoreTests {
  @Test("module version is set")
  func versionIsSet() {
    #expect(!EarsDataStore.version.isEmpty)
  }
}
