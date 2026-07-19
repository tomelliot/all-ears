import Foundation
import Testing

@testable import EarsCore

@Suite("SourceID")
struct SourceIDTests {
  @Test("keeps its natural form as the raw value")
  func rawValue() {
    #expect(SourceID("app:us.zoom.xos").rawValue == "app:us.zoom.xos")
  }

  @Test("replaces path-unsafe characters for the on-disk directory name")
  func pathSafe() {
    #expect(SourceID("mic").pathSafe == "mic")
    #expect(SourceID("app:us.zoom.xos").pathSafe == "app_us.zoom.xos")
    #expect(SourceID("browser:meet").pathSafe == "browser_meet")
    #expect(SourceID("device:AB/CD").pathSafe == "device_AB_CD")
  }

  @Test("derives the source class from the id prefix")
  func sourceClass() {
    #expect(SourceID("mic").sourceClass == .mic)
    #expect(SourceID("system").sourceClass == .system)
    #expect(SourceID("app:us.zoom.xos").sourceClass == .app)
    #expect(SourceID("browser:meet").sourceClass == .browser)
    #expect(SourceID("device:0x1234").sourceClass == .device)
    #expect(SourceID("weird:thing").sourceClass == nil)
  }

  @Test("derives the detail after the first colon")
  func detail() {
    #expect(SourceID("app:us.zoom.xos").detail == "us.zoom.xos")
    #expect(SourceID("browser:meet").detail == "meet")
    #expect(SourceID("device:AB/CD").detail == "AB/CD")
    #expect(SourceID("mic").detail == nil)
    #expect(SourceID("system").detail == nil)
    #expect(SourceID("app:").detail == nil)
  }

  @Test("is expressible as a string literal and Hashable")
  func literalAndHashable() {
    let id: SourceID = "mic"
    #expect(id == SourceID("mic"))
    #expect(Set([id, "mic", "system"]).count == 2)
  }

  @Test("encodes as a bare string")
  func codableAsString() throws {
    let data = try JSONEncoder().encode(SourceID("app:us.zoom.xos"))
    #expect(String(decoding: data, as: UTF8.self) == "\"app:us.zoom.xos\"")
    let decoded = try JSONDecoder().decode(SourceID.self, from: data)
    #expect(decoded == SourceID("app:us.zoom.xos"))
  }
}
