import EarsCore
import Foundation
import Testing

@testable import EarsIPC

/// End-to-end tests against real Unix-domain sockets at a temp path. Unlike the
/// microphone, a Unix socket needs no OS permission, so the real transport is
/// exercised directly here (tier-2 glue), complementing the fake-transport
/// logic tests in `ControlSocketServerTests`.
@Suite("Network transport integration")
struct NetworkTransportIntegrationTests {
  /// A short, unique temp socket path. `sockaddr_un.sun_path` caps at 104
  /// bytes, so `/tmp` (not the long scratchpad dir) keeps us well under.
  private func tempSocketPath() -> String {
    "/tmp/ears-ipc-\(UUID().uuidString).sock"
  }

  private func splitLines(_ chunk: [UInt8]) -> [[UInt8]] {
    var framer = LineFramer()
    return framer.append(chunk)
  }

  @Test("single request/response round-trip over a real socket")
  func realRoundTrip() async throws {
    let path = tempSocketPath()
    let listener = try await NetworkSocketListener.bind(toPath: path)
    let server = ControlSocketServer(
      listener: listener, identity: ControlServerIdentity(daemon: "earsd test", bootID: "boot-net")
    ) { call in
      #expect(call == .flush)
      return ControlReply(result: EmptyData())
    }
    let runner = Task { await server.run() }

    let client = try await ControlSocketClient.connect(toPath: path)
    let hello = try await client.hello(client: "test/0")
    #expect(hello.bootID == "boot-net")
    let response = try await client.send(.flush, expecting: EmptyData.self)
    #expect(response == EmptyData())

    await client.close()
    await server.shutdown()
    _ = await runner.value
  }

  @Test("multiple concurrent clients each receive their own correct response")
  func concurrentClients() async throws {
    let path = tempSocketPath()
    let listener = try await NetworkSocketListener.bind(toPath: path)
    // Echo the requested session id back as the uptime.
    let server = ControlSocketServer(
      listener: listener, identity: ControlServerIdentity(daemon: "earsd test", bootID: "boot-net")
    ) { call in
      guard case .sessionClose(let id) = call else {
        return .failure(.internalError, "no")
      }
      return ControlReply(result: StatusData(uptimeSeconds: Int(id) ?? -1, sources: []))
    }
    let runner = Task { await server.run() }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          let client = try await ControlSocketClient.connect(toPath: path)
          _ = try await client.hello(client: "test/0")
          let response = try await client.send(
            .sessionClose(id: String(index)), expecting: StatusData.self)
          #expect(response == StatusData(uptimeSeconds: index, sources: []))
          await client.close()
        }
      }
      try await group.waitForAll()
    }

    await server.shutdown()
    _ = await runner.value
  }

  @Test("subscribe then receive published events over a real socket")
  func realSubscribe() async throws {
    let path = tempSocketPath()
    let listener = try await NetworkSocketListener.bind(toPath: path)
    let server = ControlSocketServer(
      listener: listener, identity: ControlServerIdentity(daemon: "earsd test", bootID: "boot-net")
    ) { call in
      guard case .subscribe = call else { return .failure(.internalError, "no") }
      return ControlReply(result: SnapshotData(rev: 5, meetings: [], sources: [], sessions: []))
    }
    let runner = Task { await server.run() }

    let client = try await ControlSocketClient.connect(toPath: path)
    _ = try await client.hello(client: "test/0")
    let (snapshot, events) = try await client.subscribe(SubscribeParams())
    #expect(snapshot.rev == 5)

    // The subscription is registered before the snapshot reply is sent, so
    // it is guaranteed live by now.
    while await server.subscriberCount == 0 { await Task.yield() }
    await server.publish(EventFrame(event: .source(id: "mic", state: .paused), rev: 6))
    await server.publish(EventFrame(event: .source(id: "mic", state: .capturing), rev: 7))

    var received: [EventFrame] = []
    for await frame in events {
      received.append(frame)
      if received.count == 2 { break }
    }
    #expect(
      received == [
        EventFrame(event: .source(id: "mic", state: .paused), rev: 6),
        EventFrame(event: .source(id: "mic", state: .capturing), rev: 7),
      ])

    await client.close()
    await server.shutdown()
    _ = await runner.value
  }

  @Test("connecting to a nonexistent socket path fails clearly")
  func connectToMissingPathFails() async throws {
    let path = tempSocketPath()  // never bound
    await #expect(throws: SocketTransportError.self) {
      _ = try await ControlSocketClient.connect(toPath: path)
    }
  }

  @Test("server shutdown closes the connection so a later request fails")
  func shutdownClosesRealConnections() async throws {
    let path = tempSocketPath()
    let listener = try await NetworkSocketListener.bind(toPath: path)
    let server = ControlSocketServer(
      listener: listener, identity: ControlServerIdentity(daemon: "earsd test", bootID: "boot-net")
    ) { _ in
      ControlReply(result: EmptyData())
    }
    let runner = Task { await server.run() }

    let client = try await ControlSocketClient.connect(toPath: path)
    _ = try await client.hello(client: "test/0")
    _ = try await client.send(.flush, expecting: EmptyData.self)

    await server.shutdown()
    _ = await runner.value

    // The server closed the connection; a subsequent request gets no response
    // and surfaces as a thrown error rather than hanging forever.
    await #expect(throws: (any Error).self) {
      _ = try await client.send(.flush, expecting: EmptyData.self)
    }
    await client.close()
  }
}
