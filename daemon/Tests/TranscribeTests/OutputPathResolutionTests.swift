import EarsCore
import Foundation
import Testing

@testable import transcribe

@Suite("OutputPathResolution")
struct OutputPathResolutionTests {
  private let start = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z
  private let outputRoot = URL(fileURLWithPath: "/output-root")

  @Test("no --out builds <output-root>/<date>/<time>_<slug>.transcript.{md,json}")
  func defaultPathShape() {
    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: start, sourceIDs: [SourceID("mic")],
      explicitOut: nil)
    #expect(
      paths.markdown.path == "/output-root/2026-07-17/10-30-00_mic.transcript.md")
    #expect(
      paths.sidecar.path == "/output-root/2026-07-17/10-30-00_mic.transcript.json")
  }

  @Test("multiple sources join into the slug")
  func multipleSourcesJoinSlug() {
    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: start,
      sourceIDs: [SourceID("mic"), SourceID("app:us.zoom.xos")], explicitOut: nil)
    #expect(
      paths.markdown.path
        == "/output-root/2026-07-17/10-30-00_mic_app_us.zoom.xos.transcript.md")
  }

  @Test("--out overrides the markdown path, and the sidecar swaps its extension to json")
  func explicitOutOverridesPath() {
    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: start, sourceIDs: [SourceID("mic")],
      explicitOut: "/tmp/custom/my-transcript.md")
    #expect(paths.markdown.path == "/tmp/custom/my-transcript.md")
    #expect(paths.sidecar.path == "/tmp/custom/my-transcript.json")
  }

  @Test("sessionIdentifier combines the start timestamp and source slug")
  func sessionIdentifierShape() {
    let identifier = OutputPathResolution.sessionIdentifier(
      requestedStart: start, sourceIDs: [SourceID("mic")])
    #expect(identifier == "2026-07-17T10-30-00Z_mic")
  }

  @Test("a sessionSlug overrides the joined source ids in the filename")
  func sessionSlugOverridesSourceSlug() {
    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: start,
      sourceIDs: [SourceID("mic"), SourceID("app:us.zoom.xos")], explicitOut: nil,
      sessionSlug: "standup")
    #expect(paths.markdown.path == "/output-root/2026-07-17/10-30-00_standup.transcript.md")
  }
}
