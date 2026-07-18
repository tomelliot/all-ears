import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import EarsIPC
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Integration tests for ``EarsDaemon``, the top-level composition that wires
/// ``CaptureActor``/``SessionRegistry``/``ControlServer``/``PowerObserver``/
/// ``ShutdownCoordinator`` into one runnable daemon. Every source is backed by
/// a ``SyntheticCaptureBackend`` (or a scripted failure) via the
/// ``CaptureBackendFactory`` seam, so nothing here touches Core Audio or TCC.
@Suite("EarsDaemon")
struct EarsDaemonTests {
  private let nativeRate = 48_000
  private let asrRate = 16_000

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EarsDaemonTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A short, unique temp socket path. `sockaddr_un.sun_path` caps at 104
  /// bytes, so `/tmp` (not the long scratchpad dir) keeps us well under, per
  /// `EarsIPCTests/NetworkTransportIntegrationTests`' precedent.
  private func tempSocketPath() -> String {
    "/tmp/ears-daemon-\(UUID().uuidString).sock"
  }

  private func makeDescriptor(id: SourceID, sourceClass: SourceClass) -> SourceDescriptor {
    SourceDescriptor(
      schema: 1,
      id: id,
      sourceClass: sourceClass,
      label: id.rawValue,
      nativeSampleRate: nativeRate,
      asrSampleRate: asrRate,
      storeNative: true,
      channels: 1,
      codec: "aac",
      bitrate: 64_000,
      timeCapSeconds: 7_200,
      created: Instant(secondsSinceEpoch: 1_000)
    )
  }

  private func makeBuffer(seconds: Double, value: Float = 0.5) -> AudioBuffer {
    AudioBuffer(
      samples: [Float](repeating: value, count: Int(seconds * Double(nativeRate))),
      sampleRate: nativeRate)
  }

  private struct StartFailure: Error {}

  /// A ``CaptureBackend`` whose `start()` always throws, standing in for a
  /// denied-permission source without touching real TCC.
  private struct FailingStartCaptureBackend: CaptureBackend {
    let source: SourceID
    func start() async throws -> AsyncStream<AudioBuffer> { throw StartFailure() }
    func stop() async {}
  }

  @Test(
    "one source's start() failure is isolated: it lands in .error, other sources keep capturing")
  func perSourceStartupFailureIsolation() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))
    let loggedMessages = Mutex<[String]>([])

    let configuration = EarsDaemonConfiguration(
      sources: [
        makeDescriptor(id: "mic", sourceClass: .mic),
        makeDescriptor(id: "system", sourceClass: .system),
      ],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        if descriptor.id == "system" {
          return FailingStartCaptureBackend(source: descriptor.id)
        }
        return SyntheticCaptureBackend(
          source: descriptor.id, buffers: [self.makeBuffer(seconds: 0.1)])
      },
      clock: clock,
      log: { message in loggedMessages.withLock { $0.append(message) } }
    )

    // Must not throw: a single source's permission-style failure never takes
    // down the whole daemon (docs/specs/capture-daemon.md).
    try await daemon.start()

    let statuses = await daemon.statusForTesting()
    #expect(statuses["system"]?.state == .error)
    #expect(statuses["mic"]?.state == .capturing)
    #expect(loggedMessages.withLock { $0.contains { $0.contains("system") } })

    await daemon.stop()
  }

  @Test("starts every source, serves status over a real control socket, and stops cleanly")
  func endToEndSyntheticCapture() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: socketPath
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [self.makeBuffer(seconds: 0.1)])
      },
      clock: clock
    )

    try await daemon.start()

    let client = try await ControlSocketClient.connect(toPath: socketPath)
    let response = try await client.send(.status, expecting: StatusData.self)
    await client.close()

    guard case .success(let data) = response else {
      Issue.record("expected a successful status reply, got \(response)")
      return
    }
    #expect(data.sources.count == 1)
    #expect(data.sources.first?.id == "mic")
    #expect(data.sources.first?.state == .capturing)

    await daemon.stop()

    // The socket listener is torn down as part of stop(), so a fresh connect
    // attempt to the same path fails -- proof stop() actually stopped serving.
    await #expect(throws: SocketTransportError.self) {
      _ = try await ControlSocketClient.connect(toPath: socketPath)
    }
  }
}
