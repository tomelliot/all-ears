import Foundation
import Testing

@testable import EarsCore

/// Covers ``SubscribeRequest``: the pub/sub subscription request, matching
/// `docs/specs/capture-daemon.md`'s literal "Live feed" example. Kept
/// separate from ``ControlRequest`` because `subscribe` is not one of the
/// rows in the spec's command table (it transitions the
/// connection into an event stream rather than getting a
/// ``ControlResponse``), but it's still a `cmd`-tagged request worth
/// modelling from the same literal example.
@Suite("SubscribeRequest")
struct SubscribeRequestTests {
  @Test("decodes the spec's literal subscribe example")
  func decodesSpecExample() throws {
    let json = """
      {"cmd":"subscribe","events":["vad","session","segment"],"sources":["mic","app:us.zoom.xos"]}
      """
    let request = try JSONDecoder().decode(SubscribeRequest.self, from: Data(json.utf8))
    #expect(
      request
        == SubscribeRequest(
          events: [.vad, .session, .segment], sources: ["mic", "app:us.zoom.xos"]))
  }

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let request = SubscribeRequest(events: [.vad], sources: [])
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(SubscribeRequest.self, from: data)
    #expect(decoded == request)
  }

  @Test("throws when cmd is not subscribe")
  func throwsOnWrongCmd() {
    let json = """
      {"cmd":"status","events":["vad"],"sources":[]}
      """
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SubscribeRequest.self, from: Data(json.utf8))
    }
  }
}
