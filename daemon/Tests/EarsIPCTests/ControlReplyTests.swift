import EarsCore
import Foundation
import Testing

@testable import EarsIPC

@Suite("ControlReply")
struct ControlReplyTests {
  private func envelope(_ reply: ControlReply) throws -> [String: Any] {
    let data = try reply.encoded(using: JSONEncoder())
    return try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("wraps a success response into an ok/data envelope")
  func successEnvelope() throws {
    let status = StatusData(uptimeSeconds: 3600, sources: [])
    let reply = ControlReply(ControlResponse.success(status))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
    let data = try #require(json["data"] as? [String: Any])
    #expect(data["uptime_s"] as? Int == 3600)
    #expect(json["error"] == nil)
  }

  @Test("wraps a failure response into an ok:false/error envelope")
  func failureEnvelope() throws {
    let reply = ControlReply(ControlResponse<StatusData>.failure("no such source"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    #expect(json["error"] as? String == "no such source")
    #expect(json["data"] == nil)
  }

  @Test("the failure convenience uses an EmptyData-typed envelope")
  func failureConvenience() throws {
    let reply = ControlReply.failure("bad request")
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    #expect(json["error"] as? String == "bad request")
  }

  @Test("a success reply decodes back into its typed ControlResponse")
  func roundTripsThroughTypedResponse() throws {
    let status = StatusData(uptimeSeconds: 42, sources: [])
    let data = try ControlReply(ControlResponse.success(status)).encoded(using: JSONEncoder())
    let decoded = try JSONDecoder().decode(ControlResponse<StatusData>.self, from: data)
    #expect(decoded == .success(status))
  }
}
