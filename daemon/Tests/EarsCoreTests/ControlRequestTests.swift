import Foundation
import Testing

@testable import EarsCore

/// Covers ``ControlRequest``: the sixteen `cmd`s in
/// `docs/specs/capture-daemon.md`'s control-socket command table, discriminated
/// on the wire by the `"cmd"` field (mirroring ``IndexEvent``'s `"t"`-tag
/// pattern for `index.jsonl`).
@Suite("ControlRequest")
struct ControlRequestTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func decode(_ json: String) throws -> ControlRequest {
    try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
  }

  private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(ControlRequest.self, from: data)
  }

  // MARK: - No-payload commands

  @Test(
    "decodes commands with no payload",
    arguments: [
      ("{\"cmd\":\"status\"}", ControlRequest.status),
      ("{\"cmd\":\"sources.list\"}", ControlRequest.sourcesList),
      ("{\"cmd\":\"session.list\"}", ControlRequest.sessionList),
      ("{\"cmd\":\"flush\"}", ControlRequest.flush),
    ])
  func decodesNoPayloadCommands(json: String, expected: ControlRequest) throws {
    #expect(try decode(json) == expected)
  }

  // MARK: - sources.add

  @Test("decodes sources.add with a nested spec")
  func decodesSourcesAdd() throws {
    let json = """
      {"cmd":"sources.add","spec":{"id":"app:us.zoom.xos","class":"app"}}
      """
    #expect(
      try decode(json) == .sourcesAdd(SourceSpec(id: "app:us.zoom.xos", sourceClass: .app)))
  }

  // MARK: - sources.remove / enable / disable

  @Test(
    "decodes single-source commands",
    arguments: [
      (
        "{\"cmd\":\"sources.remove\",\"source\":\"app:us.zoom.xos\"}",
        ControlRequest.sourcesRemove(source: "app:us.zoom.xos")
      ),
      (
        "{\"cmd\":\"sources.enable\",\"source\":\"app:us.zoom.xos\"}",
        ControlRequest.sourcesEnable(source: "app:us.zoom.xos")
      ),
      (
        "{\"cmd\":\"sources.disable\",\"source\":\"app:us.zoom.xos\"}",
        ControlRequest.sourcesDisable(source: "app:us.zoom.xos")
      ),
    ])
  func decodesSingleSourceCommands(json: String, expected: ControlRequest) throws {
    #expect(try decode(json) == expected)
  }

  // MARK: - capture.pause / resume

  @Test("decodes capture.pause/resume scoped to one source")
  func decodesCaptureScoped() throws {
    #expect(
      try decode("{\"cmd\":\"capture.pause\",\"source\":\"mic\"}")
        == .capturePause(source: "mic"))
    #expect(
      try decode("{\"cmd\":\"capture.resume\",\"source\":\"mic\"}")
        == .captureResume(source: "mic"))
  }

  @Test("decodes capture.pause/resume with source omitted, meaning all sources")
  func decodesCaptureAll() throws {
    #expect(try decode("{\"cmd\":\"capture.pause\"}") == .capturePause(source: nil))
    #expect(try decode("{\"cmd\":\"capture.resume\"}") == .captureResume(source: nil))
  }

  // MARK: - session.open

  @Test("decodes session.open with only the required fields")
  func decodesSessionOpenMinimal() throws {
    let json = """
      {"cmd":"session.open","sources":["mic","app:us.zoom.xos"],"slug":"standup"}
      """
    #expect(
      try decode(json)
        == .sessionOpen(
          sources: ["mic", "app:us.zoom.xos"], slug: "standup", start: nil, vocab: nil,
          trigger: nil)
    )
  }

  @Test("decodes session.open with optional start and vocab")
  func decodesSessionOpenFull() throws {
    let json = """
      {"cmd":"session.open","sources":["mic"],"slug":"standup","start":"2026-07-17T10:30:00Z","vocab":"standup.txt"}
      """
    #expect(
      try decode(json)
        == .sessionOpen(
          sources: ["mic"], slug: "standup", start: base, vocab: "standup.txt", trigger: nil))
  }

  @Test("decodes session.open with an explicit trigger")
  func decodesSessionOpenWithTrigger() throws {
    let json = """
      {"cmd":"session.open","sources":["mic"],"slug":"call","trigger":"browser-extension"}
      """
    #expect(
      try decode(json)
        == .sessionOpen(
          sources: ["mic"], slug: "call", start: nil, vocab: nil, trigger: .browserExtension))
  }

  // MARK: - session.add_source

  @Test("decodes session.add_source")
  func decodesSessionAddSource() throws {
    let json = """
      {"cmd":"session.add_source","id":"2026-07-17T10-30-00Z_standup","source":"browser:meet:jane"}
      """
    #expect(
      try decode(json)
        == .sessionAddSource(id: "2026-07-17T10-30-00Z_standup", source: "browser:meet:jane"))
  }

  // MARK: - meeting.resolve

  @Test("decodes meeting.resolve")
  func decodesMeetingResolve() throws {
    let json = """
      {"cmd":"meeting.resolve","platform":"meet","external_id":"AbCdEfGhIjKl"}
      """
    #expect(try decode(json) == .meetingResolve(platform: "meet", externalID: "AbCdEfGhIjKl"))
  }

  // MARK: - session.close

  @Test("decodes session.close")
  func decodesSessionClose() throws {
    let json = """
      {"cmd":"session.close","id":"2026-07-17T10-30-00Z_standup"}
      """
    #expect(try decode(json) == .sessionClose(id: "2026-07-17T10-30-00Z_standup"))
  }

  // MARK: - mark

  @Test("decodes mark with a relative last_seconds")
  func decodesMarkRelative() throws {
    let json = """
      {"cmd":"mark","sources":["mic"],"slug":"hallway-chat","last_seconds":1800}
      """
    #expect(
      try decode(json)
        == .mark(sources: ["mic"], slug: "hallway-chat", range: .lastSeconds(1800)))
  }

  @Test("decodes mark with an absolute start/end pair")
  func decodesMarkAbsolute() throws {
    let json = """
      {"cmd":"mark","sources":["mic"],"slug":"hallway-chat","start":"2026-07-17T10:30:00Z","end":"2026-07-17T11:00:00Z"}
      """
    #expect(
      try decode(json)
        == .mark(
          sources: ["mic"], slug: "hallway-chat",
          range: .absolute(start: base, end: base.advanced(by: 1800))))
  }

  @Test("throws when mark has neither last_seconds nor start/end")
  func markThrowsWhenRangeMissing() {
    let json = """
      {"cmd":"mark","sources":["mic"],"slug":"hallway-chat"}
      """
    #expect(throws: (any Error).self) { try decode(json) }
  }

  @Test("throws when mark has both last_seconds and start/end")
  func markThrowsWhenRangeAmbiguous() {
    let json = """
      {"cmd":"mark","sources":["mic"],"slug":"hallway-chat","last_seconds":1800,"start":"2026-07-17T10:30:00Z","end":"2026-07-17T11:00:00Z"}
      """
    #expect(throws: (any Error).self) { try decode(json) }
  }

  // MARK: - ingest.open

  @Test("decodes the spec's literal ingest.open example")
  func decodesIngestOpen() throws {
    let json = """
      {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":48000,"channels":1,"encoding":"pcm_s16le"}}
      """
    #expect(
      try decode(json)
        == .ingestOpen(
          source: "browser:meet",
          format: AudioFormatSpec(sampleRate: 48000, channels: 1, encoding: "pcm_s16le")))
  }

  // MARK: - segment.publish

  @Test("decodes segment.publish with the same fields as the segment event")
  func decodesSegmentPublish() throws {
    let json = """
      {"cmd":"segment.publish","session":"2026-07-17T10-30-00Z_standup","speaker":"You","start":604.1,"end":611.9,"text":"ship it"}
      """
    #expect(
      try decode(json)
        == .segmentPublish(
          session: "2026-07-17T10-30-00Z_standup", speaker: "You", start: 604.1, end: 611.9,
          text: "ship it"))
  }

  // MARK: - Round trips and error handling

  @Test(
    "round-trips every case through encode/decode",
    arguments: [
      ControlRequest.status,
      .sourcesList,
      .sourcesAdd(SourceSpec(id: "mic", sourceClass: .mic, label: "Built-in Mic")),
      .sourcesRemove(source: "app:us.zoom.xos"),
      .sourcesEnable(source: "app:us.zoom.xos"),
      .sourcesDisable(source: "app:us.zoom.xos"),
      .capturePause(source: "mic"),
      .capturePause(source: nil),
      .captureResume(source: "mic"),
      .captureResume(source: nil),
      .sessionOpen(
        sources: ["mic", "app:us.zoom.xos"], slug: "standup", start: nil, vocab: nil,
        trigger: nil),
      .sessionOpen(
        sources: ["mic"],
        slug: "standup",
        start: Instant(secondsSinceEpoch: 1_784_284_200),
        vocab: "standup.txt",
        trigger: .browserExtension
      ),
      .sessionClose(id: "2026-07-17T10-30-00Z_standup"),
      .sessionList,
      .sessionAddSource(id: "2026-07-17T10-30-00Z_standup", source: "browser:meet:jane"),
      .meetingResolve(platform: "meet", externalID: "AbCdEfGhIjKl"),
      .mark(sources: ["mic"], slug: "hallway-chat", range: .lastSeconds(1800)),
      .mark(
        sources: ["mic"],
        slug: "hallway-chat",
        range: .absolute(
          start: Instant(secondsSinceEpoch: 1_784_284_200),
          end: Instant(secondsSinceEpoch: 1_784_286_000))
      ),
      .ingestOpen(
        source: "browser:meet",
        format: AudioFormatSpec(sampleRate: 48000, channels: 1, encoding: "pcm_s16le")),
      .segmentPublish(
        session: "2026-07-17T10-30-00Z_standup", speaker: "Speaker 2", start: 604.1, end: 611.9,
        text: "ship it"),
      .flush,
    ])
  func roundTrips(request: ControlRequest) throws {
    #expect(try roundTrip(request) == request)
  }

  @Test("throws on an unrecognised cmd")
  func unrecognisedCommand() {
    #expect(throws: (any Error).self) {
      try decode("{\"cmd\":\"mystery\"}")
    }
  }
}
