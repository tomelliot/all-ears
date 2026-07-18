import EarsCoreTestSupport
import Testing

@testable import EarsCore

@Suite("Capability protocol casting")
struct CapabilityCastingTests {
  @Test("a base-only transcriber exposes no capabilities")
  func baseOnly() {
    let transcriber: any Transcriber = NullTranscriber()
    #expect(transcriber as? StreamingTranscriber == nil)
    #expect(transcriber as? BiasingTranscriber == nil)
    #expect(transcriber as? WordTimingTranscriber == nil)
    #expect(!transcriber.info.supportsStreaming)
    #expect(!transcriber.info.supportsBiasing)
    #expect(!transcriber.info.wordTimings)
  }

  @Test("a capable transcriber casts to every capability and flags match")
  func capable() throws {
    let transcriber: any Transcriber = CapableTranscriber()
    #expect(transcriber.info.supportsStreaming)
    #expect(transcriber.info.supportsBiasing)
    #expect(transcriber.info.wordTimings)

    let streaming = try #require(transcriber as? StreamingTranscriber)
    #expect(transcriber is BiasingTranscriber)
    #expect(transcriber is WordTimingTranscriber)

    var state = DecoderState()
    let buffer = AudioBuffer(samples: Array(repeating: 0, count: 800), sampleRate: 16_000)
    _ = try streaming.step(buffer, state: &state)
    #expect(state.framesConsumed == 800)
  }
}

@Suite("Null conformances")
struct NullConformanceTests {
  private let buffer = AudioBuffer(samples: [0, 0, 0], sampleRate: 16_000)

  @Test("null transcriber and diarizer produce nothing")
  func transcriberAndDiarizer() throws {
    #expect(try NullTranscriber().transcribe(buffer, context: TranscribeContext()).isEmpty)
    #expect(try NullDiarizer().diarize(buffer).isEmpty)
  }

  @Test("null VAD reports no spans")
  func vad() throws {
    #expect(try NullVAD().detect(in: buffer).isEmpty)
  }

  @Test("null capture backend finishes immediately and reports its source")
  func captureBackend() async throws {
    let backend = NullCaptureBackend(source: "app:us.zoom.xos")
    #expect(backend.source == "app:us.zoom.xos")
    var received = 0
    for await _ in try await backend.start() { received += 1 }
    #expect(received == 0)
    await backend.stop()
  }

  @Test("null permission provider returns its fixed status")
  func permissions() async {
    let denied = NullPermissionProviding(fixedStatus: .denied)
    #expect(await denied.status(for: .systemAudio) == .denied)
    #expect(await denied.request(.microphone) == .denied)
    #expect(await NullPermissionProviding().status(for: .microphone) == .authorized)
  }

  @Test("synthetic capture backend emits its scripted buffers then finishes")
  func syntheticCaptureBackend() async throws {
    let backend = SyntheticCaptureBackend(
      source: "mic",
      buffers: [
        AudioBuffer(samples: [0.1, 0.2], sampleRate: 48_000),
        AudioBuffer(samples: [0.3], sampleRate: 48_000),
      ])
    #expect(backend.source == "mic")
    var received: [Float] = []
    for await buffer in try await backend.start() {
      received.append(contentsOf: buffer.samples)
    }
    #expect(received == [0.1, 0.2, 0.3])
    await backend.stop()
  }

  @Test("synthetic capture backend convenience init makes one mono buffer")
  func syntheticConvenienceInit() async throws {
    let backend = SyntheticCaptureBackend(sampleCount: 4, value: 0.25, sampleRate: 16_000)
    var count = 0
    for await buffer in try await backend.start() {
      #expect(buffer.sampleRate == 16_000)
      #expect(buffer.samples == [0.25, 0.25, 0.25, 0.25])
      count += 1
    }
    #expect(count == 1)
  }
}

@Suite("FakeLLMBackend")
struct FakeLLMBackendTests {
  @Test("default fake echoes the dynamic suffix and records the prompt")
  func echoesByDefault() async throws {
    let backend = FakeLLMBackend()
    let prompt = LLMPrompt(stablePrefix: "system prompt\n\n", dynamicSuffix: "raw transcript text")
    let result = try await backend.complete(prompt)
    #expect(result.text == "raw transcript text")
    let received = await backend.receivedPrompts
    #expect(received == [prompt])
  }

  @Test("scripted results are returned in order")
  func scriptedResults() async throws {
    let backend = FakeLLMBackend(results: [
      .success(LLMCompletionResult(text: "first")),
      .success(LLMCompletionResult(text: "second")),
    ])
    let first = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "a"))
    let second = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "b"))
    #expect(first.text == "first")
    #expect(second.text == "second")
  }

  @Test("a scripted failure propagates as a thrown LLMBackendError")
  func scriptedFailure() async throws {
    let backend = FakeLLMBackend(results: [
      .failure(LLMBackendError.nonZeroExit(code: 1, stderr: "boom"))
    ])
    await #expect(throws: LLMBackendError.nonZeroExit(code: 1, stderr: "boom")) {
      try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "a"))
    }
  }

  @Test("info is exposed unchanged")
  func infoExposed() {
    let backend = FakeLLMBackend(info: LLMBackendInfo(name: "fake", model: "test-model"))
    #expect(backend.info == LLMBackendInfo(name: "fake", model: "test-model"))
  }
}

@Suite("ManualClock")
struct ManualClockTests {
  @Test("stays fixed until advanced, never touching wall time")
  func controllable() {
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))
    #expect(clock.now() == Instant(secondsSinceEpoch: 1_000))
    clock.advance(by: 30)
    #expect(clock.now() == Instant(secondsSinceEpoch: 1_030))
    clock.set(Instant(secondsSinceEpoch: 42))
    #expect(clock.now() == Instant(secondsSinceEpoch: 42))
  }

  @Test("is usable through the NowProviding seam")
  func throughSeam() {
    let provider: any NowProviding = ManualClock(Instant(secondsSinceEpoch: 5))
    #expect(provider.now() == Instant(secondsSinceEpoch: 5))
  }
}
