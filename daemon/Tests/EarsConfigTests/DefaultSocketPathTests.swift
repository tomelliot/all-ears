import Testing

@testable import EarsConfig

@Suite("Default socket path")
struct DefaultSocketPathTests {
  @Test("derives <data_root>/runtime/earsd.sock")
  func derivesUnderDataRoot() {
    #expect(
      DefaultSocketPath.resolve(dataRoot: "/Users/tom/Library/Application Support/ears")
        == "/Users/tom/Library/Application Support/ears/runtime/earsd.sock")
  }

  @Test("a trailing slash on data_root doesn't produce a doubled slash")
  func trailingSlashNormalized() {
    #expect(
      DefaultSocketPath.resolve(dataRoot: "/custom/data/")
        == "/custom/data/runtime/earsd.sock")
  }
}
