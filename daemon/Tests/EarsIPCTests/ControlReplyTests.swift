import EarsCore
import Foundation
import Testing

@testable import EarsIPC

@Suite("ControlReply (v2)")
struct ControlReplyTests {
  private func frame(_ reply: ControlReply, id: RequestID = .int(7)) throws -> [String: Any] {
    let data = try reply.encoded(id: id, using: JSONEncoder())
    return try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("wraps a typed result into an id-correlated result frame")
  func resultFrame() throws {
    let status = StatusData(uptimeSeconds: 3600, sources: [])
    let json = try frame(ControlReply(result: status))
    #expect(json["id"] as? Int == 7)
    let result = try #require(json["result"] as? [String: Any])
    #expect(result["uptime_s"] as? Int == 3600)
    #expect(json["error"] == nil)
  }

  @Test("wraps a WireError into a coded error frame")
  func errorFrame() throws {
    let json = try frame(
      ControlReply(error: WireError(code: .sourceNotFound, message: "no such source")))
    #expect(json["id"] as? Int == 7)
    let error = try #require(json["error"] as? [String: Any])
    #expect(error["code"] as? String == "source_not_found")
    #expect(error["message"] as? String == "no such source")
    #expect(json["result"] == nil)
  }

  @Test("the failure convenience builds the same coded frame")
  func failureConvenience() throws {
    let json = try frame(.failure(.invalidRequest, "bad request"), id: .string("x"))
    #expect(json["id"] as? String == "x")
    let error = try #require(json["error"] as? [String: Any])
    #expect(error["code"] as? String == "invalid_request")
  }

  @Test("a result frame decodes back into its typed ControlResponseFrame")
  func roundTripsThroughTypedFrame() throws {
    let status = StatusData(uptimeSeconds: 42, sources: [])
    let data = try ControlReply(result: status).encoded(id: .int(3), using: JSONEncoder())
    let decoded = try JSONDecoder().decode(ControlResponseFrame<StatusData>.self, from: data)
    #expect(decoded == .result(id: .int(3), status))
  }
}
