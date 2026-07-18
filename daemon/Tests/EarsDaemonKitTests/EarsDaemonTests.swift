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

  @Test("writes meta.toml for each configured source at construction time")
  func writesSourceMetaTomlAtConstruction() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 5_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    _ = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: clock
    )

    let written = try SourceMetaStore.read(sourceID: "mic", dataRoot: dataRoot)
    #expect(written.id == "mic")
    #expect(written.sourceClass == .mic)
    #expect(written.nativeSampleRate == nativeRate)
    #expect(written.asrSampleRate == asrRate)
    #expect(written.timeCapSeconds == 7_200)
    #expect(written.created == Instant(secondsSinceEpoch: 1_000))
  }

  @Test(
    "reconstructing the daemon preserves an existing meta.toml's created timestamp while updating its other fields to match the current config"
  )
  func preservesExistingMetaTomlCreatedOnRestart() async throws {
    let dataRoot = try makeDataRoot()
    let originalCreated = Instant(secondsSinceEpoch: 500)
    var preExisting = makeDescriptor(id: "mic", sourceClass: .mic)
    preExisting.created = originalCreated
    preExisting.timeCapSeconds = 3_600
    try SourceMetaStore.write(preExisting, dataRoot: dataRoot)

    let configuration = EarsDaemonConfiguration(
      // A fresh config-resolution pass stamps `created` with "now" and may
      // have a different `time_cap_seconds` than what's already on disk.
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    _ = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: ManualClock(Instant(secondsSinceEpoch: 9_000))
    )

    let written = try SourceMetaStore.read(sourceID: "mic", dataRoot: dataRoot)
    #expect(written.created == originalCreated)
    #expect(written.timeCapSeconds == 7_200)
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

  @Test("a subscribed client receives session open/close events end to end")
  func endToEndSessionEvents() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: socketPath
    )

    // An empty capture script: the mic source starts and idles, so the only
    // live-feed traffic is the session lifecycle this test drives.
    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: clock
    )
    try await daemon.start()

    let watcher = try await ControlSocketClient.connect(toPath: socketPath)
    let events = try await watcher.subscribe(SubscribeRequest(events: [.session], sources: []))
    // Wait until the server has registered the subscription before driving
    // the lifecycle, else the events could fan out to nobody.
    while await daemon.subscriberCountForTesting() == 0 { await Task.yield() }

    let controller = try await ControlSocketClient.connect(toPath: socketPath)
    let openReply = try await controller.send(
      .sessionOpen(sources: ["mic"], slug: "standup", start: nil, vocab: nil),
      expecting: SessionOpenData.self)
    guard case .success(let opened) = openReply else {
      Issue.record("expected a successful session.open reply, got \(openReply)")
      return
    }
    let closeReply = try await controller.send(
      .sessionClose(id: opened.id), expecting: EmptyData.self)
    #expect(closeReply == .success(EmptyData()))
    await controller.close()

    var received: [EarsEvent] = []
    for await event in events {
      received.append(event)
      if received.count == 2 { break }
    }
    #expect(
      received == [
        .session(id: opened.id, state: .open),
        .session(id: opened.id, state: .closed),
      ])

    await watcher.close()
    await daemon.stop()
  }

  // MARK: - Dynamic browser (ingest) sources

  @Test("openIngestSource builds a dynamic browser source that writes real PCM to disk")
  func dynamicIngestSourceWritesToDisk() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let streamID = try await daemon.openIngestSource(
      label: "browser:meet:jane-a1b2", format: format)

    let samples = [Float](repeating: 0.25, count: 1600)  // 100 ms @ 16 kHz
    await daemon.pushIngestAudio(streamID: streamID, samples: samples, sampleRate: 16000)
    // stop() (called by closeIngestSource) awaits the CaptureActor's consume
    // task draining every already-yielded buffer before returning, and
    // flushes whatever's pending as a short final chunk — so no sleep is
    // needed here to avoid racing the background consume loop.
    await daemon.closeIngestSource(streamID: streamID)

    let statuses = await daemon.statusForTesting()
    let status = try #require(statuses["browser:meet:jane-a1b2"])
    #expect(status.bytesUsed > 0)
    #expect(status.state == .disabled)  // stopped by ingest.close, not left capturing

    let written = try SourceMetaStore.read(sourceID: "browser:meet:jane-a1b2", dataRoot: dataRoot)
    #expect(written.sourceClass == .browser)
    #expect(written.nativeSampleRate == 16000)
    #expect(written.asrSampleRate == 16000)
    #expect(written.storeNative == false)

    await daemon.stop()
  }

  @Test(
    "reopening the same label after a close resumes the same on-disk source rather than a fresh one"
  )
  func reopenSameLabelResumesSameSource() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let label: SourceID = "browser:meet:speaker-1"
    // A full second, not a small 100ms buffer: FilenameTimestampCodec
    // truncates chunk filenames to whole-second precision (chunks are
    // fixed-duration 30s+ in real capture, so sub-second start times never
    // collide in practice — see that type's doc comment). ChunkEncoder's
    // timeline is buffer-duration-derived, not clock-derived, so the two
    // sessions' chunks must be pushed far enough apart in accumulated
    // duration to land in different whole seconds and write distinct files,
    // or the second session's flush silently overwrites the first's file.
    let samples = [Float](repeating: 0.25, count: 16000)

    let firstStreamID = try await daemon.openIngestSource(label: label, format: format)
    await daemon.pushIngestAudio(streamID: firstStreamID, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: firstStreamID)
    let bytesAfterFirstSession = try #require(await daemon.statusForTesting()[label]?.bytesUsed)

    // Same label, a later "join": must reuse the existing CaptureActor, not
    // build a second one — a fresh stream_id each time, same source.
    let secondStreamID = try await daemon.openIngestSource(label: label, format: format)
    #expect(secondStreamID != firstStreamID)
    await daemon.pushIngestAudio(streamID: secondStreamID, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: secondStreamID)
    let bytesAfterSecondSession = try #require(await daemon.statusForTesting()[label]?.bytesUsed)

    #expect(bytesAfterSecondSession > bytesAfterFirstSession)
    #expect(await daemon.statusForTesting().keys.filter { $0 == label }.count == 1)

    await daemon.stop()
  }

  @Test("openIngestSource rejects a label that isn't a browser:* source")
  func rejectsNonBrowserLabel() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    await #expect(throws: EarsDaemon.IngestError.self) {
      _ = try await daemon.openIngestSource(label: "mic", format: format)
    }

    await daemon.stop()
  }
}
