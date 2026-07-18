import Foundation
import Network

/// Errors surfaced by the real Unix-domain-socket transport.
public enum SocketTransportError: Error, Sendable {
  /// A client connection could not be established (e.g. no daemon is
  /// listening at the path). Carries the underlying `NWError` description.
  case connectionFailed(String)
  /// The listener could not bind or start on the given path.
  case listenerFailed(String)
}

/// The real ``SocketConnection``, wrapping one `NWConnection` over a Unix
/// domain socket.
///
/// `@unchecked Sendable` justification: the only shared mutable state is the
/// `NWConnection`, whose `start`/`send`/`receive`/`cancel` are documented safe
/// to call from any queue, and the `AsyncStream.Continuation`, which is itself
/// `Sendable` and internally synchronized. No other mutable state crosses task
/// boundaries, so wrapping the connection in an actor would add hops without
/// removing any real data race.
public final class NetworkSocketConnection: SocketConnection, @unchecked Sendable {
  private let connection: NWConnection
  public let inbound: AsyncStream<[UInt8]>
  private let inboundContinuation: AsyncStream<[UInt8]>.Continuation

  /// Wrap an already-`ready` connection and begin its receive loop.
  init(ready connection: NWConnection) {
    self.connection = connection
    (inbound, inboundContinuation) = AsyncStream.makeStream()
    receiveNext()
  }

  /// Connect to a daemon listening at `path`. Throws promptly — rather than
  /// hanging — when nothing is listening: an `NWConnection` to a dead Unix
  /// path resolves to `.waiting`/`.failed` (typically `ECONNREFUSED`), both of
  /// which are treated as connect failures here.
  public static func connect(
    toPath path: String,
    queue: DispatchQueue = DispatchQueue(label: "net.tomelliot.ears.ipc.client")
  ) async throws -> NetworkSocketConnection {
    let connection = NWConnection(to: .unix(path: path), using: unixParameters())
    do {
      return try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            once.resume(returning: NetworkSocketConnection(ready: connection))
          case .failed(let error), .waiting(let error):
            connection.cancel()
            once.resume(throwing: SocketTransportError.connectionFailed("\(error)"))
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    }
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty { self.inboundContinuation.yield(Array(data)) }
      if isComplete || error != nil {
        self.inboundContinuation.finish()
        return
      }
      self.receiveNext()
    }
  }

  public func send(_ bytes: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: Data(bytes),
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        })
    }
  }

  public func close() async {
    connection.cancel()
    inboundContinuation.finish()
  }
}

/// The real ``SocketListener``, wrapping an `NWListener` bound to a Unix domain
/// socket path.
///
/// `@unchecked Sendable` justification: as with ``NetworkSocketConnection``,
/// the shared state is the `NWListener` (thread-safe control methods) and the
/// `Sendable` connections continuation.
public final class NetworkSocketListener: SocketListener, @unchecked Sendable {
  private let listener: NWListener
  /// The Unix-domain socket file to remove on ``close()``, or `nil` for a
  /// TCP listener (nothing on disk to clean up).
  private let cleanupPath: String?
  public let connections: AsyncStream<any SocketConnection>
  private let connectionsContinuation: AsyncStream<any SocketConnection>.Continuation

  private init(
    listener: NWListener,
    cleanupPath: String?,
    connections: AsyncStream<any SocketConnection>,
    continuation: AsyncStream<any SocketConnection>.Continuation
  ) {
    self.listener = listener
    self.cleanupPath = cleanupPath
    self.connections = connections
    self.connectionsContinuation = continuation
  }

  /// Bind and start listening at `path`, awaiting the listener reaching
  /// `.ready` so a client may connect immediately on return. A stale socket
  /// file at `path` (from a prior crashed run) is removed first — `bind(2)`
  /// rejects an existing path with `EADDRINUSE`.
  public static func bind(
    toPath path: String,
    queue: DispatchQueue = DispatchQueue(label: "net.tomelliot.ears.ipc.server")
  ) async throws -> NetworkSocketListener {
    try? FileManager.default.removeItem(atPath: path)

    let parameters = unixParameters()
    parameters.requiredLocalEndpoint = .unix(path: path)
    return try await startListening(using: parameters, cleanupPath: path, queue: queue)
  }

  /// Bind and start listening on `127.0.0.1:port` — **loopback only**, never
  /// a wildcard/`0.0.0.0` bind (the ingest WebSocket's security boundary
  /// relies on this; see `EarsIPC.IngestWebSocketServer`). Awaits the
  /// listener reaching `.ready` so a client may connect immediately on
  /// return.
  public static func bind(
    toLoopbackPort port: UInt16,
    queue: DispatchQueue = DispatchQueue(label: "net.tomelliot.ears.ipc.ingest-server")
  ) async throws -> NetworkSocketListener {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
    return try await startListening(using: parameters, cleanupPath: nil, queue: queue)
  }

  private static func startListening(
    using parameters: NWParameters, cleanupPath: String?, queue: DispatchQueue
  ) async throws -> NetworkSocketListener {
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw SocketTransportError.listenerFailed("\(error)")
    }

    let (connections, continuation) = AsyncStream.makeStream(of: (any SocketConnection).self)
    continuation.onTermination = { _ in listener.cancel() }

    listener.newConnectionHandler = { nwConnection in
      nwConnection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.yield(NetworkSocketConnection(ready: nwConnection))
        case .failed, .cancelled:
          nwConnection.cancel()
        default:
          break
        }
      }
      nwConnection.start(queue: queue)
    }

    let wrapper = NetworkSocketListener(
      listener: listener, cleanupPath: cleanupPath, connections: connections,
      continuation: continuation)
    try await wrapper.awaitReady(on: queue)
    return wrapper
  }

  private func awaitReady(on queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeOnce(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          once.resume(returning: ())
        case .failed(let error):
          once.resume(throwing: SocketTransportError.listenerFailed("\(error)"))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  /// The bound TCP port — only meaningful for a ``bind(toLoopbackPort:queue:)``
  /// listener; used by tests that bind to port `0` (an ephemeral port chosen
  /// by the OS) and need to learn what it actually is.
  public var boundPort: UInt16? {
    listener.port?.rawValue
  }

  public func close() async {
    listener.cancel()
    connectionsContinuation.finish()
    if let cleanupPath {
      try? FileManager.default.removeItem(atPath: cleanupPath)
    }
  }
}

/// `NWParameters` for a Unix domain stream socket: the TCP stack over a
/// `.unix` endpoint yields an `AF_UNIX`/`SOCK_STREAM` socket, the shape the
/// newline-delimited control protocol expects.
private func unixParameters() -> NWParameters {
  let parameters = NWParameters.tcp
  parameters.allowLocalEndpointReuse = true
  return parameters
}

/// Guards a `CheckedContinuation` against the double-resume that an
/// `NWConnection`/`NWListener` state handler can otherwise cause (it may fire
/// `.ready` then later `.failed`). First resume wins; the rest are ignored.
private final class ResumeOnce<Success: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Success, Error>?

  init(_ continuation: CheckedContinuation<Success, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Success) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: value)
  }

  func resume(throwing error: Error) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: error)
  }
}
