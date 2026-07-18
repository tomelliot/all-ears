import Foundation
import Testing

@testable import EarsCore

/// Covers ``ControlResponse``: the `{"ok":true,"data":...}` /
/// `{"ok":false,"error":...}` envelope from `docs/specs/capture-daemon.md`'s
/// `status` example, generic over the payload type so each call site
/// decodes exactly the payload shape its request implies.
@Suite("ControlResponse")
struct ControlResponseTests {
  @Test("decodes the spec's literal status success example")
  func decodesStatusExample() throws {
    let json = """
      {"ok":true,"data":{"uptime_s":3600,"sources":[{"id":"mic","state":"capturing","codec":"aac"}]}}
      """
    let response = try JSONDecoder().decode(
      ControlResponse<StatusData>.self, from: Data(json.utf8))
    #expect(
      response
        == .success(
          StatusData(
            uptimeSeconds: 3600,
            sources: [SourceStatus(id: "mic", state: .capturing, codec: "aac")])))
  }

  @Test("decodes the spec's literal ingest.open success example")
  func decodesIngestOpenExample() throws {
    let json = """
      {"ok":true,"data":{"stream_id":"s7"}}
      """
    let response = try JSONDecoder().decode(
      ControlResponse<IngestOpenData>.self, from: Data(json.utf8))
    #expect(response == .success(IngestOpenData(streamID: "s7")))
  }

  @Test("decodes a failure response")
  func decodesFailure() throws {
    let json = """
      {"ok":false,"error":"source not found"}
      """
    let response = try JSONDecoder().decode(ControlResponse<EmptyData>.self, from: Data(json.utf8))
    #expect(response == .failure(ControlError("source not found")))
  }

  @Test("round-trips a success response through encode/decode")
  func roundTripsSuccess() throws {
    let response = ControlResponse<IngestOpenData>.success(IngestOpenData(streamID: "s7"))
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(ControlResponse<IngestOpenData>.self, from: data)
    #expect(decoded == response)
  }

  @Test("round-trips a failure response through encode/decode")
  func roundTripsFailure() throws {
    let response = ControlResponse<EmptyData>.failure(ControlError("daemon unreachable"))
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(ControlResponse<EmptyData>.self, from: data)
    #expect(decoded == response)
  }

  @Test("encodes EmptyData as an empty object")
  func emptyDataEncodesAsEmptyObject() throws {
    let data = try JSONEncoder().encode(EmptyData())
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?.isEmpty == true)
  }
}
